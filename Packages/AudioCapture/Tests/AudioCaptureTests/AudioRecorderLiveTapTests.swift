import Foundation
import QuartzCore
import Testing
@testable import AudioCapture

@Suite("AudioRecorder live tap")
struct AudioRecorderLiveTapTests {
    @Test("Each engine has its track's queue before it starts")
    func liveTapIsSetOnBothEnginesBeforeStart() async throws {
        let ctx = try TestRecorderFactory.make()
        defer { TestRecorderFactory.cleanup(ctx) }
        let tap = LiveAudioTap()

        try await ctx.recorder.start(paths: ctx.paths, liveTap: tap)

        #expect(ctx.micEngine.liveQueueAtLastStart === tap.mic)
        #expect(ctx.systemEngine.liveQueueAtLastStart === tap.system)
        await ctx.recorder.stop()
    }

    @Test("The timeline offset is the start timestamp minus the mic anchor")
    func timelineOffsetIsStartTimestampMinusMicAnchor() async throws {
        let ctx = try TestRecorderFactory.make()
        defer { TestRecorderFactory.cleanup(ctx) }
        let anchor = CACurrentMediaTime() - 0.25
        ctx.micEngine.setFirstBufferAnchor(anchor)
        #expect(await ctx.recorder.timelineOffset == nil)

        try await ctx.recorder.start(paths: ctx.paths, liveTap: LiveAudioTap())

        let state = try #require(await firstState(of: ctx.recorder))
        let offset = try #require(await ctx.recorder.timelineOffset)
        #expect(offset == state.startTimestamp - anchor)
        #expect(offset >= 0.25)
        await ctx.recorder.stop()
        #expect(await ctx.recorder.timelineOffset == offset)
    }

    @Test("Without a mic host time the offset is unknown")
    func timelineOffsetIsNilWithoutAMicAnchor() async throws {
        let ctx = try TestRecorderFactory.make()
        defer { TestRecorderFactory.cleanup(ctx) }
        ctx.micEngine.setFirstBufferAnchor(0)

        try await ctx.recorder.start(paths: ctx.paths)

        #expect(await ctx.recorder.timelineOffset == nil)
        await ctx.recorder.stop()
    }

    @Test("Starting without a tap gives neither engine a queue")
    func startWithoutLiveTapBehavesAsToday() async throws {
        let ctx = try TestRecorderFactory.make()
        defer { TestRecorderFactory.cleanup(ctx) }
        ctx.micEngine.setFirstBufferAnchor(CACurrentMediaTime())

        try await ctx.recorder.start(paths: ctx.paths)

        #expect(ctx.micEngine.startCount == 1)
        #expect(ctx.systemEngine.startCount == 1)
        #expect(ctx.micEngine.liveQueueAtLastStart == nil)
        #expect(ctx.systemEngine.liveQueueAtLastStart == nil)
        #expect(await ctx.recorder.timelineOffset != nil)
        await ctx.recorder.stop()
        #expect(ctx.micEngine.stopCount == 1)
        #expect(ctx.systemEngine.stopCount == 1)
    }

    @Test("Stop ends both queues and detaches them from the engines")
    func stopClosesAndDetachesTheLiveTap() async throws {
        let ctx = try TestRecorderFactory.make()
        defer { TestRecorderFactory.cleanup(ctx) }
        let tap = LiveAudioTap()
        try await ctx.recorder.start(paths: ctx.paths, liveTap: tap)
        #expect(tap.mic.drainAll().isEmpty)

        await ctx.recorder.stop()

        #expect(tap.mic.drainAll() == [DrainedBlock(startTime: 0, kind: .end)])
        #expect(tap.system.drainAll() == [DrainedBlock(startTime: 0, kind: .end)])
        #expect(ctx.micEngine.liveQueue == nil)
        #expect(ctx.systemEngine.liveQueue == nil)
    }

    @Test("Stop ends both queues at the later written end, so a track that stopped early ends with a gap")
    func stopEndsBothQueuesAtOneTime() async throws {
        let ctx = try TestRecorderFactory.make()
        defer { TestRecorderFactory.cleanup(ctx) }
        let tap = LiveAudioTap()
        try await ctx.recorder.start(paths: ctx.paths, liveTap: tap)
        // The fakes write nothing; act as the writers. The system track
        // stopped writing at 4 s, as after a reconnect that ran out of retries.
        push(seconds: 10, into: tap.mic)
        push(seconds: 4, into: tap.system)

        await ctx.recorder.stop()

        let mic = tap.mic.drainAll()
        #expect(mic.gaps.isEmpty)
        #expect(mic.last == DrainedBlock(startTime: 10, kind: .end))
        let system = tap.system.drainAll()
        #expect(system.gaps == [DrainedBlock(startTime: 4, kind: .gap(duration: 6, kind: .captureGap))])
        #expect(system.last == DrainedBlock(startTime: 10, kind: .end))
    }

    @Test("A failed start closes the tap and detaches it from the engines")
    func failedStartClosesAndDetachesTheLiveTap() async throws {
        struct Boom: Error {}
        let ctx = try TestRecorderFactory.make()
        defer { TestRecorderFactory.cleanup(ctx) }
        ctx.systemEngine.setStartError(Boom())
        let tap = LiveAudioTap()

        await #expect(throws: Boom.self) {
            try await ctx.recorder.start(paths: ctx.paths, liveTap: tap)
        }

        #expect(ctx.micEngine.liveQueueAtLastStart === tap.mic)
        #expect(ctx.micEngine.liveQueue == nil)
        #expect(ctx.systemEngine.liveQueue == nil)
        #expect(tap.mic.drainAll().last?.kind == .end)
        #expect(tap.system.drainAll().last?.kind == .end)
        #expect(await ctx.recorder.timelineOffset == nil)
    }

    @Test("A start refused before the engines run still closes the tap")
    func refusedStartClosesTheLiveTap() async throws {
        let ctx = try TestRecorderFactory.make(micAuthStatus: .denied)
        defer { TestRecorderFactory.cleanup(ctx) }
        let tap = LiveAudioTap()

        await #expect(throws: CaptureError.micPermissionDenied) {
            try await ctx.recorder.start(paths: ctx.paths, liveTap: tap)
        }

        #expect(ctx.micEngine.startCount == 0)
        #expect(tap.mic.drainAll() == [DrainedBlock(startTime: 0, kind: .end)])
        #expect(tap.system.drainAll() == [DrainedBlock(startTime: 0, kind: .end)])
    }

    @Test("A start while recording leaves the running tap alone and closes the new one")
    func startWhileRecordingClosesTheNewTap() async throws {
        let ctx = try TestRecorderFactory.make()
        defer { TestRecorderFactory.cleanup(ctx) }
        let running = LiveAudioTap()
        try await ctx.recorder.start(paths: ctx.paths, liveTap: running)
        let ignored = LiveAudioTap()

        try await ctx.recorder.start(paths: ctx.paths, liveTap: ignored)

        #expect(ctx.micEngine.startCount == 1)
        #expect(ignored.mic.drainAll() == [DrainedBlock(startTime: 0, kind: .end)])
        #expect(ignored.system.drainAll() == [DrainedBlock(startTime: 0, kind: .end)])
        #expect(running.mic.drainAll().isEmpty, "the running tap stays open")
        await ctx.recorder.stop()
        #expect(running.mic.drainAll().last?.kind == .end)
    }

    @Test("A start on a spent recorder still closes the tap")
    func spentRecorderStartClosesTheLiveTap() async throws {
        let ctx = try TestRecorderFactory.make()
        defer { TestRecorderFactory.cleanup(ctx) }
        try await ctx.recorder.start(paths: ctx.paths)
        await ctx.recorder.stop()
        let tap = LiveAudioTap()

        await #expect(throws: CaptureError.recorderConsumed) {
            try await ctx.recorder.start(paths: ctx.paths, liveTap: tap)
        }

        #expect(ctx.micEngine.startCount == 1)
        #expect(ctx.micEngine.liveQueue == nil)
        #expect(ctx.systemEngine.liveQueue == nil)
        #expect(tap.mic.drainAll() == [DrainedBlock(startTime: 0, kind: .end)])
        #expect(tap.system.drainAll() == [DrainedBlock(startTime: 0, kind: .end)])
    }

    @Test("A mic start retry discards what the abandoned attempt copied")
    func micStartRetryDiscardsTheAbandonedAttempt() async throws {
        let ctx = try TestRecorderFactory.make()
        defer { TestRecorderFactory.cleanup(ctx) }
        // The first attempt writes audio but its anchor never arrives.
        ctx.micEngine.suppressFirstBuffer(forStarts: 1)
        ctx.micEngine.setFirstBufferAnchor(CACurrentMediaTime())
        let mic = ctx.micEngine
        ctx.micEngine.onStart = {
            guard let queue = mic.liveQueue else { return }
            let attempt = Float(mic.startCount)
            [Float](repeating: attempt, count: 2400).withUnsafeBufferPointer { samples in
                guard let base = samples.baseAddress else { return }
                queue.pushSamples(base, frameCount: 2400, sampleRate: 24000, channelCount: 1, startTime: 0)
            }
        }
        let tap = LiveAudioTap()

        try await ctx.recorder.start(paths: ctx.paths, liveTap: tap)

        #expect(ctx.micEngine.startCount == 2)
        let blocks = tap.mic.drainAll()
        #expect(blocks.count == 1)
        #expect(blocks.allSamples.allSatisfy { $0 == 2 })
        await ctx.recorder.stop()
    }

    /// Pushes `seconds` of 100 ms blocks from t = 0, as a writer would.
    private func push(seconds: Int, into queue: LiveAudioQueue) {
        let block = [Float](repeating: 0.1, count: 2400)
        block.withUnsafeBufferPointer { samples in
            guard let base = samples.baseAddress else { return }
            for index in 0 ..< seconds * 10 {
                queue.pushSamples(
                    base, frameCount: 2400, sampleRate: 24000, channelCount: 1,
                    startTime: Double(index) / 10
                )
            }
        }
    }

    private func firstState(of recorder: AudioRecorder) async -> CaptureState? {
        for await state in await recorder.stateStream() {
            return state
        }
        return nil
    }
}
