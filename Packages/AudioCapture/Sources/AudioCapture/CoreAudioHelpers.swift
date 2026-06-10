import CoreAudio
import Foundation

/// Low-level Core Audio property helpers wrapping `AudioObjectGetPropertyData`.
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

    // MARK: - Device Rate Queries

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

    /// The device's current nominal sample rate (Hz).
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

    /// Sets a device's nominal sample rate. HAL applies asynchronously.
    @discardableResult
    static func setNominalSampleRate(_ rate: Double, for deviceID: AudioObjectID) -> OSStatus {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyNominalSampleRate,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var value = rate
        return AudioObjectSetPropertyData(
            deviceID, &address, 0, nil, UInt32(MemoryLayout<Float64>.size), &value
        )
    }

    // MARK: - Process List Listener

    struct ProcessListListener: @unchecked Sendable {
        let block: @Sendable (UInt32, UnsafePointer<AudioObjectPropertyAddress>) -> Void
        let queue: DispatchQueue
    }

    /// Registers a process-list listener. Returns nil on failure.
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

    struct ProcessPropertyListener: @unchecked Sendable {
        let objectID: AudioObjectID
        let propertySelector: AudioObjectPropertySelector
        let block: @Sendable (UInt32, UnsafePointer<AudioObjectPropertyAddress>) -> Void
        let queue: DispatchQueue
    }

    /// Registers a per-process property listener. Returns nil on failure.
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

// MARK: - Device Info Queries

extension CoreAudioHelpers {
    /// Human-readable device name (e.g. "MacBook Pro Speakers").
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

    /// Transport type for a device (e.g. built-in, USB, Bluetooth).
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

    /// Returns the stream format (ASBD) for a device on the given scope.
    static func streamFormat(
        for deviceID: AudioObjectID,
        scope: AudioObjectPropertyScope
    ) -> AudioStreamBasicDescription? {
        getPropertyData(
            objectID: deviceID,
            address: AudioObjectPropertyAddress(
                mSelector: kAudioDevicePropertyStreamFormat,
                mScope: scope,
                mElement: kAudioObjectPropertyElementMain
            ),
            type: AudioStreamBasicDescription.self
        )
    }

    /// Preferred channel layout for a device as raw bytes.
    static func channelLayoutData(
        for deviceID: AudioObjectID,
        scope: AudioObjectPropertyScope
    ) -> Data? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyPreferredChannelLayout,
            mScope: scope,
            mElement: kAudioObjectPropertyElementMain
        )
        var size: UInt32 = 0
        var status = AudioObjectGetPropertyDataSize(
            deviceID, &address, 0, nil, &size
        )
        guard status == noErr, size > 0 else { return nil }

        var data = Data(count: Int(size))
        status = data.withUnsafeMutableBytes { rawBuf in
            guard let ptr = rawBuf.baseAddress else { return OSStatus(-1) }
            return AudioObjectGetPropertyData(
                deviceID, &address, 0, nil, &size, ptr
            )
        }
        guard status == noErr else { return nil }
        return data
    }

    /// Number of channels on a device for the given scope.
    static func channelCount(
        for deviceID: AudioObjectID,
        scope: AudioObjectPropertyScope
    ) -> UInt32? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreamConfiguration,
            mScope: scope,
            mElement: kAudioObjectPropertyElementMain
        )
        var size: UInt32 = 0
        var status = AudioObjectGetPropertyDataSize(
            deviceID, &address, 0, nil, &size
        )
        guard status == noErr, size > 0 else { return nil }

        let buffer = UnsafeMutableRawPointer.allocate(
            byteCount: Int(size),
            alignment: MemoryLayout<AudioBufferList>.alignment
        )
        defer { buffer.deallocate() }

        status = AudioObjectGetPropertyData(
            deviceID, &address, 0, nil, &size, buffer
        )
        guard status == noErr else { return nil }

        let abl = buffer.assumingMemoryBound(to: AudioBufferList.self)
        let bufs = UnsafeMutableAudioBufferListPointer(abl)
        var total: UInt32 = 0
        for buf in bufs {
            total += buf.mNumberChannels
        }
        return total
    }
}
