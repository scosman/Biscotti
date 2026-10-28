import Foundation
import Testing
@testable import AudioCapture

@Suite("Live audio queue")
struct LiveAudioQueueTests {
    @Test("Blocks drain in order with their times, formats and samples")
    func pushThenDrainPreservesOrderAndTimes() {
        let queue = LiveAudioQueue(slotCount: 8, slotCapacityFloats: 16)
        push(queue, [1, 2, 3, 4], sampleRate: 4, startTime: 0)
        queue.pushGap(startTime: 1, duration: 0.5, kind: .captureGap)
        push(queue, [5, 6, 7, 8, 9, 10], sampleRate: 4, channelCount: 2, startTime: 1.5)

        #expect(queue.drainAll() == [
            DrainedBlock(startTime: 0, kind: .samples([1, 2, 3, 4], sampleRate: 4, channelCount: 1)),
            DrainedBlock(startTime: 1, kind: .gap(duration: 0.5, kind: .captureGap)),
            DrainedBlock(startTime: 1.5, kind: .samples([5, 6, 7, 8, 9, 10], sampleRate: 4, channelCount: 2))
        ])
        #expect(queue.drainAll().isEmpty)
        #expect(queue.droppedDuration == 0)
    }

    @Test("A block larger than a slot is split at frame boundaries with continuous times")
    func blockLargerThanSlotIsSplitWithContinuousTimes() {
        let queue = LiveAudioQueue(slotCount: 8, slotCapacityFloats: 4)
        let mono: [Float] = (0 ..< 10).map(Float.init)
        push(queue, mono, sampleRate: 10, startTime: 2)
        // Stereo: 4 floats per slot hold 2 frames; 5 frames need 3 slots.
        let stereo: [Float] = (100 ..< 110).map(Float.init)
        push(queue, stereo, sampleRate: 10, channelCount: 2, startTime: 3)

        let blocks = queue.drainAll()
        #expect(blocks.map(\.frameCount) == [4, 4, 2, 2, 2, 1])
        for (block, expected) in zip(blocks, [2, 2.4, 2.8, 3, 3.2, 3.4]) {
            #expect(abs(block.startTime - expected) < 1e-12)
        }
        Array(blocks.prefix(3)).expectContinuous(from: 2)
        Array(blocks.suffix(3)).expectContinuous(from: 3)
        #expect(Array(blocks.prefix(3)).allSamples == mono)
        #expect(Array(blocks.suffix(3)).allSamples == stereo)
    }

    @Test("A full queue drops the newest blocks and reports them as one gap before the next block")
    func overflowDropsNewestAndEmitsOneGapBeforeNextBlock() {
        let queue = LiveAudioQueue(slotCount: 2, slotCapacityFloats: 4)
        push(queue, [1, 1], sampleRate: 2, startTime: 0)
        push(queue, [2, 2], sampleRate: 2, startTime: 1)
        push(queue, [3, 3], sampleRate: 2, startTime: 2) // dropped
        push(queue, [4, 4], sampleRate: 2, startTime: 3) // dropped

        #expect(queue.drainAll().map(\.samples) == [[1, 1], [2, 2]])

        push(queue, [5, 5], sampleRate: 2, startTime: 4)
        #expect(queue.drainAll() == [
            DrainedBlock(startTime: 2, kind: .gap(duration: 2, kind: .overflow)),
            DrainedBlock(startTime: 4, kind: .samples([5, 5], sampleRate: 2, channelCount: 1))
        ])
    }

    @Test("The overflow gap covers exactly the dropped samples and gaps")
    func overflowGapDurationEqualsDroppedDuration() {
        let queue = LiveAudioQueue(slotCount: 2, slotCapacityFloats: 1024)
        push(queue, [Float](repeating: 0, count: 480), sampleRate: 48000, startTime: 0)
        push(queue, [Float](repeating: 0, count: 441), sampleRate: 48000, startTime: 0.01)
        queue.pushGap(startTime: 0.0191875, duration: 0.25, kind: .captureGap) // dropped
        push(queue, [Float](repeating: 0, count: 300), sampleRate: 24000, startTime: 0.2691875) // dropped
        #expect(queue.drainAll().count == 2)

        push(queue, [0], sampleRate: 24000, startTime: 0.2816875)
        let dropped = 0.25 + 300.0 / 24000
        let blocks = queue.drainAll()
        #expect(blocks.count == 2)
        #expect(blocks.first?.gapKind == .overflow)
        #expect(blocks.first?.startTime == 0.0191875)
        #expect(abs((blocks.first?.duration ?? 0) - dropped) < 1e-12)
        #expect(abs(queue.droppedDuration - dropped) < 1e-12)
        blocks.expectContinuous(from: 0.0191875)

        push(queue, [0], sampleRate: 24000, startTime: 0.3)
        #expect(queue.drainAll().map(\.samples) == [[0]])
    }

    @Test("A block that needs more slots than are free is dropped whole")
    func blockNeedingMoreSlotsThanFreeIsDroppedWhole() {
        let queue = LiveAudioQueue(slotCount: 2, slotCapacityFloats: 2)
        push(queue, [1, 1], sampleRate: 2, startTime: 0)
        push(queue, [2, 2, 2, 2], sampleRate: 2, startTime: 1) // needs 2 slots, 1 free
        // One slot is free, but the pending overflow gap needs one too.
        push(queue, [3], sampleRate: 2, startTime: 3)

        #expect(queue.drainAll().map(\.samples) == [[1, 1]])
        push(queue, [4], sampleRate: 2, startTime: 3.5)
        #expect(queue.drainAll() == [
            DrainedBlock(startTime: 1, kind: .gap(duration: 2.5, kind: .overflow)),
            DrainedBlock(startTime: 3.5, kind: .samples([4], sampleRate: 2, channelCount: 1))
        ])
    }

    @Test("Closing a full queue still ends the input after every block")
    func closeIsSeenEvenWhenQueueIsFull() {
        let queue = LiveAudioQueue(slotCount: 2, slotCapacityFloats: 4)
        push(queue, [1, 1], sampleRate: 2, startTime: 0)
        queue.pushGap(startTime: 1, duration: 0.5, kind: .captureGap)
        queue.close(at: 1.5)

        #expect(queue.drainAll() == [
            DrainedBlock(startTime: 0, kind: .samples([1, 1], sampleRate: 2, channelCount: 1)),
            DrainedBlock(startTime: 1, kind: .gap(duration: 0.5, kind: .captureGap)),
            DrainedBlock(startTime: 1.5, kind: .end)
        ])
    }

    @Test("Audio dropped at the end of input is reported before the end")
    func pendingOverflowIsEmittedBeforeEnd() {
        // One slot: the closing gap must not need a free slot.
        let queue = LiveAudioQueue(slotCount: 1, slotCapacityFloats: 4)
        push(queue, [1, 1], sampleRate: 2, startTime: 0)
        push(queue, [2, 2], sampleRate: 2, startTime: 1) // dropped
        push(queue, [3, 3, 3], sampleRate: 2, startTime: 2) // dropped
        queue.close(at: queue.writtenEnd)

        #expect(queue.drainAll() == [
            DrainedBlock(startTime: 0, kind: .samples([1, 1], sampleRate: 2, channelCount: 1)),
            DrainedBlock(startTime: 1, kind: .gap(duration: 2.5, kind: .overflow)),
            DrainedBlock(startTime: 3.5, kind: .end)
        ])
        #expect(queue.droppedDuration == 2.5)
    }

    @Test("A slot stays the consumer's until its drain callback returns")
    func slotMemoryValidUntilCallbackReturns() {
        let queue = LiveAudioQueue(slotCount: 2, slotCapacityFloats: 4)
        push(queue, [1, 1, 1, 1], sampleRate: 4, startTime: 0)
        push(queue, [2, 2, 2, 2], sampleRate: 4, startTime: 1)

        var seen: [[Float]] = []
        var isFirst = true
        queue.drain { block in
            guard case let .samples(samples, _, _) = block.kind else { return }
            if isFirst {
                isFirst = false
                // The writer keeps writing while the pump reads.
                push(queue, [9, 9, 9, 9], sampleRate: 4, startTime: 2)
            }
            seen.append(Array(samples))
        }

        #expect(seen == [[1, 1, 1, 1], [2, 2, 2, 2]])
        queue.close(at: 3)
        #expect(queue.drainAll() == [
            DrainedBlock(startTime: 2, kind: .gap(duration: 1, kind: .overflow)),
            DrainedBlock(startTime: 3, kind: .end)
        ])
    }

    @Test("The end is drained once, and pushes after closing are ignored")
    func endIsDrainedOnceAndLaterPushesAreIgnored() {
        let queue = LiveAudioQueue(slotCount: 4, slotCapacityFloats: 4)
        queue.close(at: 0)
        push(queue, [1], sampleRate: 1, startTime: 0)
        queue.pushGap(startTime: 1, duration: 1, kind: .captureGap)

        #expect(queue.drainAll() == [DrainedBlock(startTime: 0, kind: .end)])
        #expect(queue.drainAll().isEmpty)
    }

    @Test("A track that stopped writing before the recording's end reports the rest as a capture gap")
    func closingAfterTheTrackStoppedReportsTheMissingTail() {
        let queue = LiveAudioQueue(slotCount: 1, slotCapacityFloats: 4)
        push(queue, [1, 1], sampleRate: 2, startTime: 0)
        push(queue, [2, 2], sampleRate: 2, startTime: 1) // dropped
        queue.close(at: 12)

        #expect(queue.drainAll() == [
            DrainedBlock(startTime: 0, kind: .samples([1, 1], sampleRate: 2, channelCount: 1)),
            DrainedBlock(startTime: 1, kind: .gap(duration: 1, kind: .overflow)),
            DrainedBlock(startTime: 2, kind: .gap(duration: 10, kind: .captureGap)),
            DrainedBlock(startTime: 12, kind: .end)
        ])
        #expect(queue.droppedDuration == 1)
    }

    @Test("A shortfall under the threshold is the writers' stop skew, not a gap")
    func shortShortfallIsNotAGap() {
        let queue = LiveAudioQueue(slotCount: 4, slotCapacityFloats: 4)
        push(queue, [1, 1], sampleRate: 2, startTime: 0)
        queue.close(at: 1 + LiveAudioQueue.missingTailThreshold - 0.01)

        let blocks = queue.drainAll()
        #expect(blocks.gaps.isEmpty)
        #expect(blocks.last?.kind == .end)
        #expect(blocks.last?.startTime == 1 + LiveAudioQueue.missingTailThreshold - 0.01)
    }

    @Test("Closing before the track's own end still ends after its last block")
    func closingEarlierThanTheTrackEndsAtItsEnd() {
        let queue = LiveAudioQueue(slotCount: 4, slotCapacityFloats: 4)
        push(queue, [1, 1], sampleRate: 2, startTime: 0)
        queue.close(at: 0.5)

        #expect(queue.drainAll().last == DrainedBlock(startTime: 1, kind: .end))
    }

    @Test("Reset empties the queue for a new start attempt from t = 0")
    func resetEmptiesTheQueueForANewAttempt() {
        let queue = LiveAudioQueue(slotCount: 2, slotCapacityFloats: 4)
        push(queue, [1, 1], sampleRate: 2, startTime: 0)
        push(queue, [2, 2], sampleRate: 2, startTime: 1)
        push(queue, [3, 3], sampleRate: 2, startTime: 2) // dropped

        queue.reset()
        #expect(queue.writtenEnd == 0)
        push(queue, [4, 4], sampleRate: 2, startTime: 0)
        queue.close(at: queue.writtenEnd)

        #expect(queue.drainAll() == [
            DrainedBlock(startTime: 0, kind: .samples([4, 4], sampleRate: 2, channelCount: 1)),
            DrainedBlock(startTime: 1, kind: .end)
        ])
    }

    struct WriterBlocks: CustomTestStringConvertible {
        let track: String
        let frames: Int
        let sampleRate: Double

        var testDescription: String {
            "\(track): \(frames) frames at \(Int(sampleRate)) Hz"
        }
    }

    @Test("Each tap queue holds at least 5 s of its writer's real blocks", arguments: [
        WriterBlocks(track: "system", frames: 512, sampleRate: 48000),
        WriterBlocks(track: "mic", frames: 2400, sampleRate: 24000),
        WriterBlocks(track: "mic", frames: 512, sampleRate: 24000)
    ])
    func tapQueuesHoldFiveSeconds(blocks: WriterBlocks) {
        let tap = LiveAudioTap()
        let queue = blocks.track == "mic" ? tap.mic : tap.system
        let samples = [Float](repeating: 0, count: blocks.frames)
        let blockSeconds = Double(blocks.frames) / blocks.sampleRate
        // Push a minute of blocks with nothing draining, as during a stalled pump.
        for index in 0 ..< Int(60 / blockSeconds) {
            push(queue, samples, sampleRate: blocks.sampleRate, startTime: Double(index) * blockSeconds)
        }
        queue.close(at: queue.writtenEnd)

        let drained = queue.drainAll()
        let heldSeconds = drained.sampleBlocks.reduce(0) { $0 + $1.duration }
        #expect(heldSeconds >= 5)
        #expect(drained.gaps.map(\.gapKind) == [.overflow])
        #expect(tap.mic !== tap.system)
    }

    private func push(
        _ queue: LiveAudioQueue,
        _ samples: [Float],
        sampleRate: Double,
        channelCount: Int = 1,
        startTime: TimeInterval
    ) {
        samples.withUnsafeBufferPointer { buffer in
            guard let base = buffer.baseAddress else { return }
            queue.pushSamples(
                base, frameCount: samples.count / channelCount, sampleRate: sampleRate,
                channelCount: channelCount, startTime: startTime
            )
        }
    }
}
