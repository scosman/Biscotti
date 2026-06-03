import CoreAudio
import Foundation

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
}
