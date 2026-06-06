import CoreAudio
import Foundation

/// Low-level Core Audio property helpers.
///
/// These wrap `AudioObjectGetPropertyData` for common patterns (scalar,
/// string, array). They are internal — the public API uses higher-level
/// types built on top.
enum CoreAudioHelpers {
    // MARK: - Property Getters

    static func getPropertyData<T>(
        objectID: AudioObjectID,
        address: AudioObjectPropertyAddress,
        type _: T.Type
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
        type _: T.Type
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
        return processIDs.compactMap { parseAudioProcess(objectID: $0) }
    }

    private static func parseAudioProcess(objectID: AudioObjectID) -> AudioProcess? {
        let bundleID = getStringProperty(
            objectID: objectID,
            address: AudioObjectPropertyAddress(
                mSelector: kAudioProcessPropertyBundleID,
                mScope: kAudioObjectPropertyScopeGlobal,
                mElement: kAudioObjectPropertyElementMain
            )
        )

        let pid: pid_t = getPropertyData(
            objectID: objectID,
            address: AudioObjectPropertyAddress(
                mSelector: kAudioProcessPropertyPID,
                mScope: kAudioObjectPropertyScopeGlobal,
                mElement: kAudioObjectPropertyElementMain
            ),
            type: pid_t.self
        ) ?? 0

        let ioState = processIOState(for: objectID)

        return AudioProcess(
            id: objectID,
            bundleID: bundleID,
            pid: pid,
            isRunningInput: ioState.isRunningInput,
            isRunningOutput: ioState.isRunningOutput
        )
    }

    // MARK: - Device Queries

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
