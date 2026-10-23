import CoreAudio
import Foundation
import os
import Synchronization

private let logger = Logger(subsystem: "net.scosman.biscotti.audiocapture", category: "DeviceChange")

/// Live device-change provider using Core Audio property listeners.
///
/// Listens for `kAudioHardwarePropertyDefaultOutputDevice` and
/// `kAudioHardwarePropertyDefaultInputDevice` changes on the system
/// audio object, emitting `DeviceChangeEvent` values.
///
/// It also follows the *current* default output device and listens for
/// `kAudioDevicePropertyNominalSampleRate` and `kAudioDevicePropertyStreamFormat`
/// on it, re-registering whenever the default changes. A Bluetooth headset
/// that flips from A2DP to HFP when a call starts keeps the same device ID
/// (so no default-device event fires) but changes its sample rate, which
/// silently breaks the system tap (GitHub #88). A rate/format change is
/// reported as `.outputChanged` so the existing reconnect path runs.
final class LiveDeviceChangeProvider: DeviceChangeProvider, @unchecked Sendable {
    func deviceChanges() -> AsyncStream<DeviceChangeEvent> {
        AsyncStream { continuation in
            let subscription = Subscription(continuation: continuation)
            subscription.start()
            continuation.onTermination = { @Sendable _ in
                subscription.stop()
            }
        }
    }
}

/// One consumer's set of Core Audio listeners. Lives as long as its
/// `AsyncStream` and tears every listener down on termination.
private final class Subscription: @unchecked Sendable {
    typealias ListenerBlock = @Sendable (UInt32, UnsafePointer<AudioObjectPropertyAddress>) -> Void

    private static let defaultOutputAddress = AudioObjectPropertyAddress(
        mSelector: kAudioHardwarePropertyDefaultOutputDevice,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain
    )

    private static let defaultInputAddress = AudioObjectPropertyAddress(
        mSelector: kAudioHardwarePropertyDefaultInputDevice,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain
    )

    /// Device-scoped properties watched on the current default output device.
    private static let outputDeviceAddresses = [
        AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyNominalSampleRate,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        ),
        AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreamFormat,
            mScope: kAudioDevicePropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain
        )
    ]

    /// The parts of the output format whose change invalidates the tap.
    private struct FormatKey: Equatable {
        var nominalRate: Double
        var streamRate: Double
        var channels: UInt32
        var formatID: AudioFormatID

        static func current(for deviceID: AudioObjectID) -> FormatKey {
            let stream = CoreAudioHelpers.streamFormat(for: deviceID, scope: kAudioDevicePropertyScopeOutput)
            return FormatKey(
                nominalRate: CoreAudioHelpers.nominalSampleRate(for: deviceID) ?? 0,
                streamRate: stream?.mSampleRate ?? 0,
                channels: stream?.mChannelsPerFrame ?? 0,
                formatID: stream?.mFormatID ?? 0
            )
        }
    }

    private struct State {
        /// Output device currently carrying the device-scoped listeners.
        var outputDeviceID: AudioObjectID = kAudioObjectUnknown
        /// Last observed format on that device, to drop no-op notifications.
        var outputFormat = FormatKey(nominalRate: 0, streamRate: 0, channels: 0, formatID: 0)
        var stopped = false
    }

    private let continuation: AsyncStream<DeviceChangeEvent>.Continuation
    private let queue = DispatchQueue(label: "net.scosman.biscotti.device-change", qos: .userInitiated)
    private let state = Mutex(State())

    // Listener blocks are stored so the exact same closures can be removed.
    private var defaultOutputBlock: ListenerBlock = { _, _ in }
    private var defaultInputBlock: ListenerBlock = { _, _ in }
    private var outputDeviceBlock: ListenerBlock = { _, _ in }

    init(continuation: AsyncStream<DeviceChangeEvent>.Continuation) {
        self.continuation = continuation
        defaultOutputBlock = { [weak self] _, _ in self?.handleDefaultOutputChanged() }
        defaultInputBlock = { [weak self] _, _ in self?.handleDefaultInputChanged() }
        outputDeviceBlock = { [weak self] _, _ in self?.handleOutputDevicePropertyChanged() }
    }

    func start() {
        var outAddr = Self.defaultOutputAddress
        var inAddr = Self.defaultInputAddress
        AudioObjectAddPropertyListenerBlock(
            AudioObjectID(kAudioObjectSystemObject), &outAddr, queue, defaultOutputBlock
        )
        AudioObjectAddPropertyListenerBlock(
            AudioObjectID(kAudioObjectSystemObject), &inAddr, queue, defaultInputBlock
        )
        followDefaultOutputDevice()
    }

    func stop() {
        state.withLock { $0.stopped = true }
        var outAddr = Self.defaultOutputAddress
        var inAddr = Self.defaultInputAddress
        AudioObjectRemovePropertyListenerBlock(
            AudioObjectID(kAudioObjectSystemObject), &outAddr, queue, defaultOutputBlock
        )
        AudioObjectRemovePropertyListenerBlock(
            AudioObjectID(kAudioObjectSystemObject), &inAddr, queue, defaultInputBlock
        )
        let previous = state.withLock { locked -> AudioObjectID in
            let id = locked.outputDeviceID
            locked.outputDeviceID = kAudioObjectUnknown
            return id
        }
        removeOutputDeviceListeners(from: previous)
    }

    // MARK: - System-object listeners (on `queue`)

    private func handleDefaultOutputChanged() {
        guard !isStopped else { return }
        logger.info("Default output device changed")
        followDefaultOutputDevice()
        continuation.yield(.outputChanged)
    }

    private func handleDefaultInputChanged() {
        guard !isStopped else { return }
        logger.info("Default input device changed")
        continuation.yield(.inputChanged)
    }

    // MARK: - Output-device listeners (on `queue`)

    /// Moves the rate/format listeners onto the current default output
    /// device and caches its format. No-op if the device is unchanged.
    private func followDefaultOutputDevice() {
        let newID = CoreAudioHelpers.defaultOutputDeviceID() ?? kAudioObjectUnknown
        let previous = state.withLock { locked -> AudioObjectID? in
            guard !locked.stopped, locked.outputDeviceID != newID else { return nil }
            let old = locked.outputDeviceID
            locked.outputDeviceID = newID
            locked.outputFormat = FormatKey.current(for: newID)
            return old
        }
        guard let previous else { return }
        removeOutputDeviceListeners(from: previous)
        addOutputDeviceListeners(to: newID)
    }

    private func handleOutputDevicePropertyChanged() {
        let changed = state.withLock { locked -> (from: FormatKey, to: FormatKey)? in
            guard !locked.stopped, locked.outputDeviceID != kAudioObjectUnknown else { return nil }
            let now = FormatKey.current(for: locked.outputDeviceID)
            guard now != locked.outputFormat else { return nil }
            let before = locked.outputFormat
            locked.outputFormat = now
            return (before, now)
        }
        guard let changed else { return }
        logger.notice(
            "Output device format changed: rate \(changed.from.nominalRate, privacy: .public) → \(changed.to.nominalRate, privacy: .public), stream \(changed.from.streamRate, privacy: .public)/\(changed.from.channels, privacy: .public)ch → \(changed.to.streamRate, privacy: .public)/\(changed.to.channels, privacy: .public)ch -- treating as output change"
        )
        continuation.yield(.outputChanged)
    }

    private func addOutputDeviceListeners(to deviceID: AudioObjectID) {
        guard deviceID != kAudioObjectUnknown else { return }
        for address in Self.outputDeviceAddresses {
            var addr = address
            let status = AudioObjectAddPropertyListenerBlock(deviceID, &addr, queue, outputDeviceBlock)
            if status != noErr {
                logger.warning(
                    "Could not watch output device \(deviceID, privacy: .public) selector \(address.mSelector, privacy: .public): \(status, privacy: .public)"
                )
            }
        }
    }

    private func removeOutputDeviceListeners(from deviceID: AudioObjectID) {
        guard deviceID != kAudioObjectUnknown else { return }
        for address in Self.outputDeviceAddresses {
            var addr = address
            // The device may already be gone (unplugged); a failure here is expected.
            AudioObjectRemovePropertyListenerBlock(deviceID, &addr, queue, outputDeviceBlock)
        }
    }

    private var isStopped: Bool {
        state.withLock { $0.stopped }
    }
}
