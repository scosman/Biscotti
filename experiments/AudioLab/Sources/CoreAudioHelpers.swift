import CoreAudio
import Foundation
import os

/// Central `os.Logger` instances for AudioLab.
///
/// This is a dev/experiment app, so we log verbosely: every major lifecycle
/// event (start / stop / reconfigure / route change / error), a periodic
/// heartbeat per capture, and watchdog faults when a stream stalls. We never
/// log per audio frame — heartbeats summarise counters instead.
///
/// View live:
///   log stream --predicate 'subsystem == "com.biscotti.experiments.audiolab"' --level debug
/// Or open Console.app and filter the subsystem.
enum Log {
    static let subsystem = "com.biscotti.experiments.audiolab"

    static let mic = Logger(subsystem: subsystem, category: "MicCapture")
    static let system = Logger(subsystem: subsystem, category: "SystemAudioCapture")
    static let coordinator = Logger(subsystem: subsystem, category: "RecordingCoordinator")
    static let device = Logger(subsystem: subsystem, category: "Device")
}

/// Convenience wrappers that force `.public` privacy so dynamic values (device
/// names, formats, statuses) are actually visible in Console — by default
/// `os.Logger` redacts interpolated strings as `<private>`. Names are chosen to
/// avoid colliding with `Logger`'s own `info`/`warning`/`error`/`fault`.
extension Logger {
    func event(_ message: String) { info("\(message, privacy: .public)") }
    func warn(_ message: String) { warning("\(message, privacy: .public)") }
    func err(_ message: String) { error("\(message, privacy: .public)") }
}

/// Formats a Core Audio `OSStatus` as its signed integer plus, when the bytes
/// are printable, the four-character code (e.g. `560227702 ('!obj')`). Most
/// Core Audio / AudioToolbox errors are FourCCs that are unreadable as ints.
func osStatusString(_ status: OSStatus) -> String {
    guard status != noErr else { return "noErr" }
    let raw = UInt32(bitPattern: status)
    let bytes = [
        UInt8((raw >> 24) & 0xFF),
        UInt8((raw >> 16) & 0xFF),
        UInt8((raw >> 8) & 0xFF),
        UInt8(raw & 0xFF),
    ]
    if bytes.allSatisfy({ $0 >= 0x20 && $0 < 0x7F }), let cc = String(bytes: bytes, encoding: .ascii) {
        return "\(status) ('\(cc)')"
    }
    return "\(status)"
}

enum CoreAudioHelpers {

    // MARK: - Property Getters

    static func getPropertyData<T>(
        objectID: AudioObjectID,
        address: AudioObjectPropertyAddress,
        type: T.Type
    ) -> T? {
        var address = address
        var size = UInt32(MemoryLayout<T>.size)
        let value = UnsafeMutableRawPointer.allocate(
            byteCount: Int(size),
            alignment: MemoryLayout<T>.alignment
        )
        defer { value.deallocate() }

        let status = AudioObjectGetPropertyData(objectID, &address, 0, nil, &size, value)
        guard status == noErr else { return nil }
        return value.load(as: T.self)
    }

    static func getStringProperty(
        objectID: AudioObjectID,
        address: AudioObjectPropertyAddress
    ) -> String? {
        var address = address
        var size: UInt32 = 0
        var status = AudioObjectGetPropertyDataSize(objectID, &address, 0, nil, &size)
        guard status == noErr, size > 0 else { return nil }

        let buffer = UnsafeMutableRawPointer.allocate(
            byteCount: Int(size),
            alignment: MemoryLayout<CFString>.alignment
        )
        defer { buffer.deallocate() }

        status = AudioObjectGetPropertyData(objectID, &address, 0, nil, &size, buffer)
        guard status == noErr else { return nil }

        // AudioObjectGetPropertyData returns a +1 CFStringRef for string properties
        let cfStr = Unmanaged<CFString>.fromOpaque(
            buffer.load(as: UnsafeRawPointer.self)
        ).takeRetainedValue()
        return cfStr as String
    }

    static func getPropertyArray<T>(
        objectID: AudioObjectID,
        address: AudioObjectPropertyAddress,
        type: T.Type
    ) -> [T] {
        var address = address
        var size: UInt32 = 0
        var status = AudioObjectGetPropertyDataSize(objectID, &address, 0, nil, &size)
        guard status == noErr, size > 0 else { return [] }

        let count = Int(size) / MemoryLayout<T>.size
        let buffer = UnsafeMutableRawPointer.allocate(
            byteCount: Int(size),
            alignment: MemoryLayout<T>.alignment
        )
        defer { buffer.deallocate() }

        status = AudioObjectGetPropertyData(objectID, &address, 0, nil, &size, buffer)
        guard status == noErr else { return [] }

        let typedPtr = buffer.bindMemory(to: T.self, capacity: count)
        return Array(UnsafeBufferPointer(start: typedPtr, count: count))
    }

    // MARK: - Process Enumeration

    static func allAudioProcesses() -> [AudioProcess] {
        let processIDs = getPropertyArray(
            objectID: AudioObjectID(kAudioObjectSystemObject),
            address: AudioObjectPropertyAddress(
                mSelector: kAudioHardwarePropertyProcessObjectList,
                mScope: kAudioObjectPropertyScopeGlobal,
                mElement: kAudioObjectPropertyElementMain
            ),
            type: AudioObjectID.self
        )

        return processIDs.compactMap { processID in
            guard let bundleID = getStringProperty(
                objectID: processID,
                address: AudioObjectPropertyAddress(
                    mSelector: kAudioProcessPropertyBundleID,
                    mScope: kAudioObjectPropertyScopeGlobal,
                    mElement: kAudioObjectPropertyElementMain
                )
            ) else { return nil }

            let pid: pid_t = getPropertyData(
                objectID: processID,
                address: AudioObjectPropertyAddress(
                    mSelector: kAudioProcessPropertyPID,
                    mScope: kAudioObjectPropertyScopeGlobal,
                    mElement: kAudioObjectPropertyElementMain
                ),
                type: pid_t.self
            ) ?? 0

            let isRunningInput: UInt32 = getPropertyData(
                objectID: processID,
                address: AudioObjectPropertyAddress(
                    mSelector: kAudioProcessPropertyIsRunningInput,
                    mScope: kAudioObjectPropertyScopeGlobal,
                    mElement: kAudioObjectPropertyElementMain
                ),
                type: UInt32.self
            ) ?? 0

            let isRunningOutput: UInt32 = getPropertyData(
                objectID: processID,
                address: AudioObjectPropertyAddress(
                    mSelector: kAudioProcessPropertyIsRunningOutput,
                    mScope: kAudioObjectPropertyScopeGlobal,
                    mElement: kAudioObjectPropertyElementMain
                ),
                type: UInt32.self
            ) ?? 0

            return AudioProcess(
                id: processID,
                bundleID: bundleID,
                pid: pid,
                isRunningInput: isRunningInput != 0,
                isRunningOutput: isRunningOutput != 0
            )
        }
    }

    // MARK: - Device Queries

    /// Returns the AudioObjectID for the default system output device.
    static func defaultOutputDeviceID() -> AudioObjectID? {
        getPropertyData(
            objectID: AudioObjectID(kAudioObjectSystemObject),
            address: AudioObjectPropertyAddress(
                mSelector: kAudioHardwarePropertyDefaultOutputDevice,
                mScope: kAudioObjectPropertyScopeGlobal,
                mElement: kAudioObjectPropertyElementMain
            ),
            type: AudioObjectID.self
        )
    }

    /// Returns the UID string for a given audio device ID.
    static func deviceUID(for deviceID: AudioObjectID) -> String? {
        getStringProperty(
            objectID: deviceID,
            address: AudioObjectPropertyAddress(
                mSelector: kAudioDevicePropertyDeviceUID,
                mScope: kAudioObjectPropertyScopeGlobal,
                mElement: kAudioObjectPropertyElementMain
            )
        )
    }

    /// Returns the AudioObjectID for the default system input device.
    static func defaultInputDeviceID() -> AudioObjectID? {
        getPropertyData(
            objectID: AudioObjectID(kAudioObjectSystemObject),
            address: AudioObjectPropertyAddress(
                mSelector: kAudioHardwarePropertyDefaultInputDevice,
                mScope: kAudioObjectPropertyScopeGlobal,
                mElement: kAudioObjectPropertyElementMain
            ),
            type: AudioObjectID.self
        )
    }

    // MARK: - Device Diagnostics

    /// Human-readable device name (e.g. "MacBook Pro Microphone").
    static func deviceName(for deviceID: AudioObjectID) -> String? {
        getStringProperty(
            objectID: deviceID,
            address: AudioObjectPropertyAddress(
                mSelector: kAudioObjectPropertyName,
                mScope: kAudioObjectPropertyScopeGlobal,
                mElement: kAudioObjectPropertyElementMain
            )
        )
    }

    /// The device's current nominal sample rate (Hz). A voice-processing
    /// meeting app often drops the built-in mic to a voice rate (16/24 kHz).
    static func nominalSampleRate(for deviceID: AudioObjectID) -> Double? {
        getPropertyData(
            objectID: deviceID,
            address: AudioObjectPropertyAddress(
                mSelector: kAudioDevicePropertyNominalSampleRate,
                mScope: kAudioObjectPropertyScopeGlobal,
                mElement: kAudioObjectPropertyElementMain
            ),
            type: Float64.self
        )
    }

    /// Whether *any* process (including other apps) currently has IO running on
    /// this device. A meeting app holding the mic shows up here.
    static func isDeviceRunningSomewhere(_ deviceID: AudioObjectID) -> Bool? {
        guard let value: UInt32 = getPropertyData(
            objectID: deviceID,
            address: AudioObjectPropertyAddress(
                mSelector: kAudioDevicePropertyDeviceIsRunningSomewhere,
                mScope: kAudioObjectPropertyScopeGlobal,
                mElement: kAudioObjectPropertyElementMain
            ),
            type: UInt32.self
        ) else { return nil }
        return value != 0
    }

    /// The device's transport type. Useful to spot when the default input has
    /// been swapped to a voice-processing aggregate / virtual device.
    static func transportType(for deviceID: AudioObjectID) -> UInt32? {
        getPropertyData(
            objectID: deviceID,
            address: AudioObjectPropertyAddress(
                mSelector: kAudioDevicePropertyTransportType,
                mScope: kAudioObjectPropertyScopeGlobal,
                mElement: kAudioObjectPropertyElementMain
            ),
            type: UInt32.self
        )
    }

    /// The device's input-scope volume scalar (0…1), i.e. the System Settings
    /// input slider. A voice-processing app's AGC can drag this low for *all*
    /// clients (WebKit Bug 218012), so logging it tells us whether our quiet
    /// capture is hardware-gain ducking vs. the raw array just being low. The
    /// built-in mic usually carries volume on channel element 1, not main(0).
    static func inputVolumeScalar(for deviceID: AudioObjectID) -> Float? {
        for element: AudioObjectPropertyElement in [kAudioObjectPropertyElementMain, 1] {
            var address = AudioObjectPropertyAddress(
                mSelector: kAudioDevicePropertyVolumeScalar,
                mScope: kAudioObjectPropertyScopeInput,
                mElement: element
            )
            guard AudioObjectHasProperty(deviceID, &address) else { continue }
            if let value: Float32 = getPropertyData(objectID: deviceID, address: address, type: Float32.self) {
                return value
            }
        }
        return nil
    }

    static func transportTypeString(_ type: UInt32) -> String {
        switch type {
        case kAudioDeviceTransportTypeBuiltIn: return "built-in"
        case kAudioDeviceTransportTypeAggregate: return "aggregate"
        case kAudioDeviceTransportTypeVirtual: return "virtual"
        case kAudioDeviceTransportTypeUSB: return "usb"
        case kAudioDeviceTransportTypeBluetooth: return "bluetooth"
        case kAudioDeviceTransportTypeBluetoothLE: return "bluetooth-le"
        case kAudioDeviceTransportTypeHDMI: return "hdmi"
        case kAudioDeviceTransportTypeDisplayPort: return "displayport"
        case kAudioDeviceTransportTypeAirPlay: return "airplay"
        case kAudioDeviceTransportTypeAVB: return "avb"
        case kAudioDeviceTransportTypeThunderbolt: return "thunderbolt"
        case kAudioDeviceTransportTypeUnknown: return "unknown"
        default: return "0x" + String(type, radix: 16)
        }
    }

    /// One-line snapshot of the current default input device plus every process
    /// holding input. Logged at mic start and by the stall watchdog so we can
    /// see whether a meeting app (FaceTime → `com.apple.avconferenced`, browser
    /// meetings → `com.apple.WebKit.GPU`, Slack → `…slackmacgap.helper`) owns
    /// the mic in voice-processing mode.
    static func inputDiagnosticsSnapshot() -> String {
        var parts: [String] = []

        if let deviceID = defaultInputDeviceID(), deviceID != kAudioObjectUnknown {
            let name = deviceName(for: deviceID) ?? "?"
            let uid = deviceUID(for: deviceID) ?? "?"
            let rate = nominalSampleRate(for: deviceID).map { "\(Int($0))Hz" } ?? "?"
            let transport = transportType(for: deviceID).map(transportTypeString) ?? "?"
            let running = isDeviceRunningSomewhere(deviceID).map { $0 ? "running" : "idle" } ?? "?"
            let volume = inputVolumeScalar(for: deviceID).map { String(format: "vol=%.2f", $0) } ?? "vol=?"
            parts.append("default-input id=\(deviceID) \"\(name)\" uid=\(uid) \(rate) \(transport) \(running) \(volume)")
        } else {
            parts.append("default-input <none>")
        }

        let inputHolders = allAudioProcesses().filter { $0.isRunningInput }
        if inputHolders.isEmpty {
            parts.append("input-holders: none")
        } else {
            let described = inputHolders.map { "\($0.bundleID)(pid \($0.pid))" }.joined(separator: ", ")
            parts.append("input-holders: \(described)")
        }

        return parts.joined(separator: " | ")
    }

    // MARK: - Listener Registration

    struct ProcessListListener {
        let block: AudioObjectPropertyListenerBlock
        let queue: DispatchQueue
    }

    static func addProcessListListener(
        queue: DispatchQueue,
        handler: @escaping () -> Void
    ) -> ProcessListListener? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyProcessObjectList,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )

        let block: AudioObjectPropertyListenerBlock = { _, _ in
            handler()
        }

        let status = AudioObjectAddPropertyListenerBlock(
            AudioObjectID(kAudioObjectSystemObject),
            &address,
            queue,
            block
        )

        return status == noErr ? ProcessListListener(block: block, queue: queue) : nil
    }

    static func removeProcessListListener(_ listener: ProcessListListener) {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyProcessObjectList,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        AudioObjectRemovePropertyListenerBlock(
            AudioObjectID(kAudioObjectSystemObject),
            &address,
            listener.queue,
            listener.block
        )
    }

    // MARK: - Per-Process Property Listeners

    // @unchecked because AudioObjectPropertyListenerBlock lacks a Sendable annotation
    // in the CoreAudio headers, but our blocks only capture Sendable values.
    struct ProcessPropertyListener: @unchecked Sendable {
        let objectID: AudioObjectID
        let propertySelector: AudioObjectPropertySelector
        let block: AudioObjectPropertyListenerBlock
        let queue: DispatchQueue
    }

    static func addProcessPropertyListener(
        processID: AudioObjectID,
        property: AudioObjectPropertySelector,
        queue: DispatchQueue,
        handler: @escaping @Sendable () -> Void
    ) -> ProcessPropertyListener? {
        var address = AudioObjectPropertyAddress(
            mSelector: property,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )

        let block: AudioObjectPropertyListenerBlock = { _, _ in
            handler()
        }

        let status = AudioObjectAddPropertyListenerBlock(
            processID,
            &address,
            queue,
            block
        )

        return status == noErr
            ? ProcessPropertyListener(
                objectID: processID,
                propertySelector: property,
                block: block,
                queue: queue
            )
            : nil
    }

    static func removeProcessPropertyListener(_ listener: ProcessPropertyListener) {
        var address = AudioObjectPropertyAddress(
            mSelector: listener.propertySelector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        AudioObjectRemovePropertyListenerBlock(
            listener.objectID,
            &address,
            listener.queue,
            listener.block
        )
    }

    // MARK: - Single-Process I/O State

    static func processIOState(for processID: AudioObjectID) -> (isRunningInput: Bool, isRunningOutput: Bool) {
        let isRunningInput: UInt32 = getPropertyData(
            objectID: processID,
            address: AudioObjectPropertyAddress(
                mSelector: kAudioProcessPropertyIsRunningInput,
                mScope: kAudioObjectPropertyScopeGlobal,
                mElement: kAudioObjectPropertyElementMain
            ),
            type: UInt32.self
        ) ?? 0

        let isRunningOutput: UInt32 = getPropertyData(
            objectID: processID,
            address: AudioObjectPropertyAddress(
                mSelector: kAudioProcessPropertyIsRunningOutput,
                mScope: kAudioObjectPropertyScopeGlobal,
                mElement: kAudioObjectPropertyElementMain
            ),
            type: UInt32.self
        ) ?? 0

        return (isRunningInput != 0, isRunningOutput != 0)
    }
}
