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

    // MARK: - Process List Listener

    /// Handle for a system-level process list listener, used for removal.
    struct ProcessListListener: @unchecked Sendable {
        let block: @Sendable (UInt32, UnsafePointer<AudioObjectPropertyAddress>) -> Void
        let queue: DispatchQueue
    }

    /// Registers a listener for `kAudioHardwarePropertyProcessObjectList` changes.
    /// Returns a handle that must be passed to `removeProcessListListener` for cleanup,
    /// or `nil` if registration failed.
    @discardableResult
    static func addProcessListListener(
        queue: DispatchQueue,
        handler: @escaping @Sendable () -> Void
    ) -> ProcessListListener? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyProcessObjectList,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        let block: @Sendable (UInt32, UnsafePointer<AudioObjectPropertyAddress>) -> Void = { _, _ in
            handler()
        }
        let status = AudioObjectAddPropertyListenerBlock(
            AudioObjectID(kAudioObjectSystemObject), &address, queue, block
        )
        guard status == noErr else { return nil }
        return ProcessListListener(block: block, queue: queue)
    }

    /// Removes a previously-registered process list listener.
    static func removeProcessListListener(_ listener: ProcessListListener) {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyProcessObjectList,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        AudioObjectRemovePropertyListenerBlock(
            AudioObjectID(kAudioObjectSystemObject), &address, listener.queue, listener.block
        )
    }

    // MARK: - Per-Process Property Listener

    /// Handle for a per-process property listener, used for removal.
    struct ProcessPropertyListener: @unchecked Sendable {
        let objectID: AudioObjectID
        let propertySelector: AudioObjectPropertySelector
        let block: @Sendable (UInt32, UnsafePointer<AudioObjectPropertyAddress>) -> Void
        let queue: DispatchQueue
    }

    /// Registers a listener for a specific property on a single audio process object.
    /// Returns `nil` if the process ID is invalid (registration fails).
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
        let block: @Sendable (UInt32, UnsafePointer<AudioObjectPropertyAddress>) -> Void = { _, _ in
            handler()
        }
        let status = AudioObjectAddPropertyListenerBlock(processID, &address, queue, block)
        guard status == noErr else { return nil }
        return ProcessPropertyListener(
            objectID: processID, propertySelector: property, block: block, queue: queue
        )
    }

    /// Removes a previously-registered per-process property listener.
    static func removeProcessPropertyListener(_ listener: ProcessPropertyListener) {
        var address = AudioObjectPropertyAddress(
            mSelector: listener.propertySelector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        AudioObjectRemovePropertyListenerBlock(
            listener.objectID, &address, listener.queue, listener.block
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
