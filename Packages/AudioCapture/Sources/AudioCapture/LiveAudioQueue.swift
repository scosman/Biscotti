import Foundation
import Synchronization

/// Why a stretch of a track's live timeline has no samples.
public enum LiveAudioGapKind: Sendable, Equatable {
    /// The system track's leading silence before its first buffer. Nothing was missed.
    case notStarted
    /// Capture lost this stretch: the writer filled a gap (a reconnect or a
    /// stall) with silence, or the track stopped writing before the recording did.
    case captureGap
    /// The live queue was full, so the live copy dropped audio. The file still has it.
    case overflow
}

/// One block drained from a `LiveAudioQueue`.
public struct LiveAudioBlock {
    public enum Kind {
        /// Interleaved Float32 samples. The pointer is valid only inside the drain callback.
        case samples(UnsafeBufferPointer<Float>, sampleRate: Double, channelCount: Int)
        case gap(duration: TimeInterval, kind: LiveAudioGapKind)
        /// The recording stopped and every earlier block has been drained.
        case end
    }

    /// Seconds on the recording timeline: t = 0 is the first mic frame written to the file.
    public let startTime: TimeInterval
    public let kind: Kind

    public init(startTime: TimeInterval, kind: Kind) {
        self.startTime = startTime
        self.kind = kind
    }
}

/// Carries one track's audio, as its writer puts it in the AAC file, to the
/// live transcription pump.
///
/// Single producer (the track's writer thread), single consumer (the pump).
/// The producer never waits, allocates, locks or logs: when the queue is full
/// it drops the block and reports the dropped time as one `.overflow` gap
/// before its next block. The consumer releases a slot only after its drain
/// callback returns, so the samples stay valid while it reads them. Closing
/// needs no slot, so the consumer always sees `.end`.
public final class LiveAudioQueue: @unchecked Sendable {
    private enum SlotContent {
        case samples(frameCount: Int, sampleRate: Double, channelCount: Int)
        case gap(duration: TimeInterval, kind: LiveAudioGapKind)
    }

    private struct Slot {
        var startTime: TimeInterval
        var content: SlotContent
    }

    private let slotCount: Int
    private let slotCapacityFloats: Int
    private let sampleMemory: UnsafeMutablePointer<Float>
    private let slots: UnsafeMutablePointer<Slot>

    /// Blocks the producer has published and the consumer has released. Both
    /// only grow; a block's slot is its position modulo `slotCount`.
    private let published = Atomic<Int>(0)
    private let consumed = Atomic<Int>(0)
    private let closed = Atomic<Bool>(false)

    // Producer only. The consumer reads them once it has seen `closed`.
    private var pendingOverflowStart: TimeInterval = 0
    private var pendingOverflowDuration: TimeInterval = 0
    private var producerEnd: TimeInterval = 0
    private var missingTailDuration: TimeInterval = 0
    private var closeTime: TimeInterval = 0

    /// Consumer only.
    private var didDrainEnd = false

    /// Total duration of the `.overflow` gaps drained so far. Consumer only.
    public private(set) var droppedDuration: TimeInterval = 0

    /// - Parameters:
    ///   - slotCount: blocks the queue holds. A writer buffer takes one slot,
    ///     or several when it holds more than `slotCapacityFloats` samples.
    ///   - slotCapacityFloats: samples (frames × channels) per slot.
    public init(slotCount: Int = 128, slotCapacityFloats: Int = 8192) {
        precondition(slotCount > 0 && slotCapacityFloats > 0, "LiveAudioQueue needs at least one slot of one sample")
        self.slotCount = slotCount
        self.slotCapacityFloats = slotCapacityFloats
        sampleMemory = .allocate(capacity: slotCount * slotCapacityFloats)
        sampleMemory.initialize(repeating: 0, count: slotCount * slotCapacityFloats)
        slots = .allocate(capacity: slotCount)
        slots.initialize(
            repeating: Slot(startTime: 0, content: .gap(duration: 0, kind: .overflow)),
            count: slotCount
        )
    }

    deinit {
        sampleMemory.deallocate()
        slots.deallocate()
    }

    // MARK: - Consumer

    /// Hands every published block to `body` in order. Once the queue is closed
    /// and empty, ends with any overflow still pending, any missing tail (see
    /// `close(at:)`), then `.end`, once.
    public func drain(_ body: (LiveAudioBlock) -> Void) {
        guard !didDrainEnd else { return }
        // Read `closed` first: if it is set, every push happened before it,
        // so the published count read next is final.
        let isClosed = closed.load(ordering: .acquiring)
        let end = published.load(ordering: .acquiring)
        var position = consumed.load(ordering: .relaxed)
        while position < end {
            hand(block(at: position % slotCount), to: body)
            position += 1
            consumed.store(position, ordering: .releasing)
        }
        guard isClosed else { return }
        if pendingOverflowDuration > 0 {
            hand(LiveAudioBlock(
                startTime: pendingOverflowStart,
                kind: .gap(duration: pendingOverflowDuration, kind: .overflow)
            ), to: body)
        }
        if missingTailDuration > 0 {
            body(LiveAudioBlock(
                startTime: producerEnd,
                kind: .gap(duration: missingTailDuration, kind: .captureGap)
            ))
        }
        body(LiveAudioBlock(startTime: closeTime, kind: .end))
        didDrainEnd = true
    }

    private func hand(_ block: LiveAudioBlock, to body: (LiveAudioBlock) -> Void) {
        if case let .gap(duration, .overflow) = block.kind { droppedDuration += duration }
        body(block)
    }

    private func block(at index: Int) -> LiveAudioBlock {
        let slot = slots[index]
        switch slot.content {
        case let .samples(frameCount, sampleRate, channelCount):
            let samples = UnsafeBufferPointer(
                start: sampleMemory + index * slotCapacityFloats,
                count: frameCount * channelCount
            )
            return LiveAudioBlock(
                startTime: slot.startTime,
                kind: .samples(samples, sampleRate: sampleRate, channelCount: channelCount)
            )
        case let .gap(duration, kind):
            return LiveAudioBlock(startTime: slot.startTime, kind: .gap(duration: duration, kind: kind))
        }
    }

    // MARK: - Producer

    /// Copies `frameCount` interleaved frames starting at `startTime`. A block
    /// larger than a slot is split at frame boundaries; it is kept or dropped whole.
    func pushSamples(
        _ source: UnsafePointer<Float>,
        frameCount: Int,
        sampleRate: Double,
        channelCount: Int,
        startTime: TimeInterval
    ) {
        guard frameCount > 0, sampleRate > 0, channelCount > 0, !closed.load(ordering: .acquiring) else { return }
        let duration = Double(frameCount) / sampleRate
        producerEnd = max(producerEnd, startTime + duration)

        let framesPerSlot = slotCapacityFloats / channelCount
        guard framesPerSlot > 0,
              var position = reserve(slotsFor: (frameCount + framesPerSlot - 1) / framesPerSlot)
        else {
            addOverflow(startTime: startTime, duration: duration)
            return
        }

        var frameOffset = 0
        while frameOffset < frameCount {
            let frames = min(framesPerSlot, frameCount - frameOffset)
            let index = position % slotCount
            (sampleMemory + index * slotCapacityFloats).update(
                from: source + frameOffset * channelCount,
                count: frames * channelCount
            )
            slots[index] = Slot(
                startTime: startTime + Double(frameOffset) / sampleRate,
                content: .samples(frameCount: frames, sampleRate: sampleRate, channelCount: channelCount)
            )
            position += 1
            frameOffset += frames
        }
        published.store(position, ordering: .releasing)
    }

    /// Records a stretch with no samples.
    func pushGap(startTime: TimeInterval, duration: TimeInterval, kind: LiveAudioGapKind) {
        guard duration > 0, !closed.load(ordering: .acquiring) else { return }
        producerEnd = max(producerEnd, startTime + duration)
        guard let position = reserve(slotsFor: 1) else {
            addOverflow(startTime: startTime, duration: duration)
            return
        }
        slots[position % slotCount] = Slot(startTime: startTime, content: .gap(duration: duration, kind: kind))
        published.store(position + 1, ordering: .releasing)
    }

    /// The end of the last block pushed or dropped: how far the writer got.
    /// Producer side; read it only once the writer has stopped.
    var writtenEnd: TimeInterval {
        producerEnd
    }

    /// A track that ends this much before the recording reports the rest as
    /// a `.captureGap`. Shorter shortfalls are the writers' normal stop skew:
    /// the two tracks of a clean recording differ by about 0.2 s
    /// (`hardware_debugging_workflow.md`).
    static let missingTailThreshold: TimeInterval = 1

    /// Ends the input at `time`, the recording's common end. If this track's
    /// audio ends at least `missingTailThreshold` earlier (it stopped writing
    /// mid-recording), the rest is reported as a `.captureGap` before `.end`.
    /// Called once the writer has stopped; later pushes are ignored.
    func close(at time: TimeInterval) {
        guard !closed.load(ordering: .acquiring) else { return }
        let missing = time - producerEnd
        missingTailDuration = missing >= Self.missingTailThreshold ? missing : 0
        closeTime = max(time, producerEnd)
        closed.store(true, ordering: .releasing)
    }

    /// Empties the queue for a new start attempt, whose writer begins again
    /// at t = 0. Safe only while no writer pushes to it and nothing drains
    /// it: the recorder calls it after the abandoned attempt's writer has
    /// stopped, and the consumer starts after `AudioRecorder.start` returns.
    func reset() {
        guard !closed.load(ordering: .acquiring) else { return }
        published.store(0, ordering: .releasing)
        consumed.store(0, ordering: .releasing)
        pendingOverflowDuration = 0
        producerEnd = 0
    }

    /// Returns the position for the first of `count` new blocks, after writing
    /// any pending overflow gap ahead of them, or nil if they do not all fit.
    private func reserve(slotsFor count: Int) -> Int? {
        let start = published.load(ordering: .relaxed)
        let free = slotCount - (start - consumed.load(ordering: .acquiring))
        let hasPendingOverflow = pendingOverflowDuration > 0
        guard count + (hasPendingOverflow ? 1 : 0) <= free else { return nil }
        guard hasPendingOverflow else { return start }
        slots[start % slotCount] = Slot(
            startTime: pendingOverflowStart,
            content: .gap(duration: pendingOverflowDuration, kind: .overflow)
        )
        pendingOverflowDuration = 0
        return start + 1
    }

    private func addOverflow(startTime: TimeInterval, duration: TimeInterval) {
        if pendingOverflowDuration == 0 { pendingOverflowStart = startTime }
        pendingOverflowDuration += duration
    }
}

/// The pair of queues one recording feeds.
///
/// Single-use: pass a new tap to each `AudioRecorder.start(paths:liveTap:)`.
/// A failed start closes the tap. Drain it only after that start returns.
public final class LiveAudioTap: Sendable {
    public let mic: LiveAudioQueue
    public let system: LiveAudioQueue

    /// Each queue holds at least 5 s of its writer's real blocks; a writer
    /// pushes one block per buffer, so they are sized by block, not by time.
    public init() {
        // 24 kHz mono blocks of about 100 ms (taps of 4,800 frames at 48 kHz):
        // one slot each, 51 s. 512-frame blocks (1,024-frame taps): 10.9 s.
        mic = LiveAudioQueue(slotCount: 512, slotCapacityFloats: 2400)
        // 512-frame IOProc buffers at 48 kHz from the mono tap: one slot each, 10.9 s.
        system = LiveAudioQueue(slotCount: 1024, slotCapacityFloats: 1024)
    }
}
