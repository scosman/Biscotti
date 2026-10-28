import Foundation
import QuartzCore
import Testing
@testable import AudioCapture

/// The system writer's live copy, checked against real ADTS files.
@Suite("System write step")
struct SystemWriteStepTests {
    @Test("A late system start is a not-started gap at zero, before the first samples")
    func leadingSilenceIsNotStartedGapAtZero() throws {
        let file = try SystemTestFile(clientRate: 48000)
        defer { file.dispose() }
        let queue = LiveAudioQueue(slotCount: 512)
        let step = SystemWriteStep()
        // The mic's first frame was at host time 100 s; the system's comes at 101.5 s.
        step.begin(micAnchorSeconds: 100, systemStartWall: CACurrentMediaTime() - 10, liveQueue: queue)
        var feed = SystemToneFeed(sampleRate: 48000, startSeconds: 101.5)
        feed.play(seconds: 1, into: step, file: file.file)
        queue.close(at: queue.writtenEnd)

        let blocks = queue.drainAll()
        #expect(blocks.first == DrainedBlock(startTime: 0, kind: .gap(duration: 1.5, kind: .notStarted)))
        #expect(blocks.dropFirst().first?.startTime == 1.5)
        #expect(blocks.gaps.count == 1)
        blocks.expectContinuous()
        #expect(blocks.allSamples == feed.played)
        #expect(try abs(file.fileDuration() - 2.5) < 0.15)
        #expect(step.writeError == nil)
    }

    @Test("A filled capture gap is reported at its place in the file")
    func gapFillEmitsCaptureGap() throws {
        let file = try SystemTestFile(clientRate: 48000)
        defer { file.dispose() }
        let queue = LiveAudioQueue(slotCount: 512)
        let step = SystemWriteStep()
        step.begin(micAnchorSeconds: 0, systemStartWall: CACurrentMediaTime(), liveQueue: queue)
        var feed = SystemToneFeed(sampleRate: 48000)
        feed.play(seconds: 1, into: step, file: file.file)
        feed.pause(seconds: 2)
        feed.play(seconds: 1, into: step, file: file.file)
        queue.close(at: queue.writtenEnd)

        let blocks = queue.drainAll()
        #expect(blocks.gaps == [DrainedBlock(startTime: 1, kind: .gap(duration: 2, kind: .captureGap))])
        blocks.expectContinuous()
        #expect(blocks.last == DrainedBlock(startTime: 4, kind: .end))
        #expect(try abs(file.fileDuration() - 4) < 0.15)
    }

    @Test("A buffer the file refuses is not copied, and the live timeline stays the file's")
    func failedWriteSendsNoLiveCopy() throws {
        let file = try SystemTestFile(clientRate: 48000, setsClientFormat: false)
        defer { file.dispose() }
        let queue = LiveAudioQueue(slotCount: 512)
        let step = SystemWriteStep()
        step.begin(micAnchorSeconds: 0, systemStartWall: CACurrentMediaTime(), liveQueue: queue)
        var feed = SystemToneFeed(sampleRate: 48000)
        feed.play(seconds: 0.5, into: step, file: file.file)
        queue.close(at: queue.writtenEnd)

        #expect(step.writeError != nil)
        #expect(queue.drainAll() == [DrainedBlock(startTime: 0, kind: .end)])
    }

    @Test("A two-channel tap reaches the queue interleaved, as written")
    func twoChannelTapIsPassedInterleaved() throws {
        let file = try SystemTestFile(clientRate: 48000, channelCount: 2)
        defer { file.dispose() }
        let queue = LiveAudioQueue(slotCount: 512)
        let step = SystemWriteStep()
        step.begin(micAnchorSeconds: 0, systemStartWall: CACurrentMediaTime(), liveQueue: queue)
        var feed = SystemToneFeed(sampleRate: 48000, channelCount: 2)
        feed.play(seconds: 1, into: step, file: file.file)
        queue.close(at: queue.writtenEnd)

        let blocks = queue.drainAll()
        #expect(blocks.sampleBlocks.allSatisfy { $0.channelCount == 2 && $0.sampleRate == 48000 })
        #expect(blocks.allSamples == feed.played)
        blocks.expectContinuous()
        #expect(try abs(file.fileDuration() - 1) < 0.15)
    }
}
