import CoreAudio
import Foundation
import Synchronization

/// Lock-free single-producer/single-consumer ring buffer for passing audio
/// buffer lists from the real-time IOProc thread to a writer thread.
/// The IOProc enqueues (producer); the writer thread dequeues (consumer).
///
/// All slot memory is pre-allocated at init to avoid heap allocation on the
/// real-time thread. Each slot has a fixed-size buffer sized for `maxFrameCount`
/// float samples. Buffers exceeding this size are dropped and counted.
final class AudioRingBuffer: @unchecked Sendable {
    struct SlotHeader {
        var dataByteSize: UInt32
        var frameCount: UInt32
        var channelCount: UInt32
        var hostTime: UInt64
        var occupied: Bool
    }

    struct Entry {
        let data: UnsafeMutableRawPointer
        let dataByteSize: UInt32
        let frameCount: UInt32
        let channelCount: UInt32
        /// Mach host time (`AudioTimeStamp.mHostTime`) of this buffer, as
        /// reported by the IOProc. Used to align the system track against the
        /// mic track's first-frame timestamp.
        let hostTime: UInt64
    }

    private let capacity: Int
    private let slotByteSize: Int
    private let slotBuffers: UnsafeMutableRawPointer
    private let slotHeaders: UnsafeMutablePointer<SlotHeader>
    private let _head: Atomic<Int>
    private let _tail: Atomic<Int>
    let droppedBuffers: Atomic<Int>

    /// - Parameters:
    ///   - capacity: Number of ring buffer slots.
    ///   - maxFrameCount: Maximum float samples per buffer. Buffers larger than
    ///     this are dropped (counted via `droppedBuffers`). Default 8192 covers
    ///     typical IOProc callbacks (1024-4096 frames) with headroom.
    init(capacity: Int = 512, maxFrameCount: Int = 8192) {
        self.capacity = capacity
        self.slotByteSize = maxFrameCount * MemoryLayout<Float>.size

        slotBuffers = .allocate(
            byteCount: capacity * slotByteSize,
            alignment: MemoryLayout<Float>.alignment
        )
        slotHeaders = .allocate(capacity: capacity)
        for i in 0..<capacity {
            slotHeaders[i] = SlotHeader(
                dataByteSize: 0, frameCount: 0, channelCount: 0, hostTime: 0, occupied: false
            )
        }
        _head = Atomic<Int>(0)
        _tail = Atomic<Int>(0)
        droppedBuffers = Atomic<Int>(0)
    }

    deinit {
        slotBuffers.deallocate()
        slotHeaders.deallocate()
    }

    /// Called from the RT thread. Copies the buffer into a pre-allocated slot.
    /// Returns false if the ring is full or the buffer exceeds the slot size;
    /// never allocates or locks.
    func enqueue(
        bufferList: UnsafePointer<AudioBufferList>,
        frameCount: UInt32,
        hostTime: UInt64
    ) -> Bool {
        let abl = bufferList.pointee
        guard let srcData = abl.mBuffers.mData else { return false }
        let byteSize = abl.mBuffers.mDataByteSize

        if Int(byteSize) > slotByteSize {
            droppedBuffers.wrappingAdd(1, ordering: .relaxed)
            return false
        }

        let currentHead = _head.load(ordering: .acquiring)
        let currentTail = _tail.load(ordering: .acquiring)
        let nextHead = (currentHead + 1) % capacity

        if nextHead == currentTail {
            droppedBuffers.wrappingAdd(1, ordering: .relaxed)
            return false
        }

        let slotPtr = slotBuffers.advanced(by: currentHead * slotByteSize)
        slotPtr.copyMemory(from: UnsafeRawPointer(srcData), byteCount: Int(byteSize))

        slotHeaders[currentHead] = SlotHeader(
            dataByteSize: byteSize,
            frameCount: frameCount,
            channelCount: abl.mBuffers.mNumberChannels,
            hostTime: hostTime,
            occupied: true
        )

        _head.store(nextHead, ordering: .releasing)
        return true
    }

    /// Called from the writer thread. Returns nil if empty. The returned Entry's
    /// `data` pointer is valid only until the next `dequeue()` call that wraps
    /// around to the same slot.
    func dequeue() -> Entry? {
        let currentTail = _tail.load(ordering: .acquiring)
        let currentHead = _head.load(ordering: .acquiring)

        if currentTail == currentHead {
            return nil
        }

        let header = slotHeaders[currentTail]
        guard header.occupied else { return nil }

        let slotPtr = slotBuffers.advanced(by: currentTail * slotByteSize)

        slotHeaders[currentTail].occupied = false
        _tail.store((currentTail + 1) % capacity, ordering: .releasing)

        return Entry(
            data: slotPtr,
            dataByteSize: header.dataByteSize,
            frameCount: header.frameCount,
            channelCount: header.channelCount,
            hostTime: header.hostTime
        )
    }
}
