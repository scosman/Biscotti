import CoreAudio
import Foundation
import os

private let logger = Logger(subsystem: "net.scosman.biscotti.audiocapture", category: "DeviceChange")

/// Live device-change provider using Core Audio property listeners.
///
/// Listens for `kAudioHardwarePropertyDefaultOutputDevice` and
/// `kAudioHardwarePropertyDefaultInputDevice` changes on the system
/// audio object, emitting `DeviceChangeEvent` values.
final class LiveDeviceChangeProvider: DeviceChangeProvider, @unchecked Sendable {
    private static let outputAddress = AudioObjectPropertyAddress(
        mSelector: kAudioHardwarePropertyDefaultOutputDevice,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain
    )

    private static let inputAddress = AudioObjectPropertyAddress(
        mSelector: kAudioHardwarePropertyDefaultInputDevice,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain
    )

    func deviceChanges() -> AsyncStream<DeviceChangeEvent> {
        AsyncStream { continuation in
            let listenerQueue = DispatchQueue(
                label: "net.scosman.biscotti.device-change",
                qos: .userInitiated
            )

            let outputBlock: @Sendable (UInt32, UnsafePointer<AudioObjectPropertyAddress>) -> Void = { _, _ in
                logger.info("Default output device changed")
                continuation.yield(.outputChanged)
            }
            let inputBlock: @Sendable (UInt32, UnsafePointer<AudioObjectPropertyAddress>) -> Void = { _, _ in
                logger.info("Default input device changed")
                continuation.yield(.inputChanged)
            }

            Self.addListeners(queue: listenerQueue, outputBlock: outputBlock, inputBlock: inputBlock)
            Self.setTermination(
                continuation: continuation,
                queue: listenerQueue,
                outputBlock: outputBlock,
                inputBlock: inputBlock
            )
        }
    }

    private static func addListeners(
        queue: DispatchQueue,
        outputBlock: @escaping @Sendable (UInt32, UnsafePointer<AudioObjectPropertyAddress>) -> Void,
        inputBlock: @escaping @Sendable (UInt32, UnsafePointer<AudioObjectPropertyAddress>) -> Void
    ) {
        var outAddr = outputAddress
        var inAddr = inputAddress
        AudioObjectAddPropertyListenerBlock(
            AudioObjectID(kAudioObjectSystemObject), &outAddr, queue, outputBlock
        )
        AudioObjectAddPropertyListenerBlock(
            AudioObjectID(kAudioObjectSystemObject), &inAddr, queue, inputBlock
        )
    }

    private static func setTermination(
        continuation: AsyncStream<DeviceChangeEvent>.Continuation,
        queue: DispatchQueue,
        outputBlock: @escaping @Sendable (UInt32, UnsafePointer<AudioObjectPropertyAddress>) -> Void,
        inputBlock: @escaping @Sendable (UInt32, UnsafePointer<AudioObjectPropertyAddress>) -> Void
    ) {
        continuation.onTermination = { @Sendable _ in
            var outAddr = outputAddress
            var inAddr = inputAddress
            AudioObjectRemovePropertyListenerBlock(
                AudioObjectID(kAudioObjectSystemObject), &outAddr, queue, outputBlock
            )
            AudioObjectRemovePropertyListenerBlock(
                AudioObjectID(kAudioObjectSystemObject), &inAddr, queue, inputBlock
            )
        }
    }
}
