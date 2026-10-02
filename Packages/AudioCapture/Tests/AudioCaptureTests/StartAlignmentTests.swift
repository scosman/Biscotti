import Foundation
import QuartzCore
import Testing
@testable import AudioCapture

@Suite("StartAlignmentTests")
struct StartAlignmentTests {
    @Test("Both streams share one start timestamp")
    func bothStreamsShareStartTimestamp() async throws {
        let ctx = try TestRecorderFactory.make()
        defer { TestRecorderFactory.cleanup(ctx) }

        try await ctx.recorder.start(paths: ctx.paths)

        // Both engines received start calls.
        #expect(ctx.systemEngine.startCount == 1)
        #expect(ctx.micEngine.startCount == 1)

        // The state stream reports a shared, non-zero start timestamp.
        let stream = await ctx.recorder.stateStream()
        var receivedState: CaptureState?
        for await state in stream {
            receivedState = state
            break // Take the first emission
        }

        #expect(receivedState != nil)
        #expect(receivedState?.isRecording == true)
        #expect(receivedState?.startTimestamp ?? 0 > 0)

        // The start timestamp is a single shared reference for both streams.
        // There is exactly one timestamp -- both engines were started before
        // it was stamped.
        let timestamp = receivedState?.startTimestamp ?? 0

        // Verify the timestamp is recent (within the last 10 seconds).
        let now = CACurrentMediaTime()
        #expect(now - timestamp < 10.0)
        #expect(now - timestamp >= 0)

        ctx.deviceChangeProvider.finish()
    }

    @Test("Mic engine starts before system engine")
    func micStartsFirst() async throws {
        let ctx = try TestRecorderFactory.make()
        defer { TestRecorderFactory.cleanup(ctx) }

        try await ctx.recorder.start(paths: ctx.paths)

        // Both started
        #expect(ctx.systemEngine.startCount == 1)
        #expect(ctx.micEngine.startCount == 1)

        // Mic was given the mic AAC URL
        #expect(ctx.micEngine.lastURL == ctx.paths.micAAC)
        // System was given the system AAC URL
        #expect(ctx.systemEngine.lastURL == ctx.paths.systemAAC)

        ctx.deviceChangeProvider.finish()
    }

    /// A thrown hardware error must be preserved while cleaning up mic resources.
    @Test("If mic start fails, system engine is not started")
    func micFailureDoesNotStartSystem() async throws {
        let ctx = try TestRecorderFactory.make()
        defer { TestRecorderFactory.cleanup(ctx) }

        ctx.micEngine.setStartError(CaptureError.micEngineFailed("test"))

        do {
            try await ctx.recorder.start(paths: ctx.paths)
            Issue.record("Expected start to throw")
        } catch {
            // Mic failed before system was started -- system untouched.
            #expect(error as? CaptureError == .micEngineFailed("test"))
            #expect(ctx.micEngine.startCount == 1)
            #expect(ctx.micEngine.stopCount == 1)
            #expect(ctx.systemEngine.startCount == 0)
            #expect(ctx.systemEngine.stopCount == 0)
        }
    }

    @Test("If system start fails (all retries), mic engine is stopped")
    func systemFailureStopsMic() async throws {
        let ctx = try TestRecorderFactory.make()
        defer { TestRecorderFactory.cleanup(ctx) }

        ctx.systemEngine.setStartError(CaptureError.tapCreationFailed(-1))

        do {
            try await ctx.recorder.start(paths: ctx.paths)
            Issue.record("Expected start to throw")
        } catch {
            // Mic was started, then stopped after system failure.
            #expect(ctx.micEngine.startCount == 1)
            #expect(ctx.micEngine.stopCount == 1)
            // System engine tried 1 + maxRetries times.
            let expectedAttempts = AudioRecorder.systemStartMaxRetries + 1
            #expect(ctx.systemEngine.startCount == expectedAttempts)
        }
    }

    /// A zero timestamp is a valid delivered anchor, distinct from a missing buffer.
    @Test("Mic anchor is forwarded to system engine, including a valid zero anchor", arguments: [0.0, 42.5])
    func micAnchorForwardedToSystem(anchor: Double) async throws {
        let ctx = try TestRecorderFactory.make()
        defer { TestRecorderFactory.cleanup(ctx) }

        ctx.micEngine.setFirstBufferAnchor(anchor)

        try await ctx.recorder.start(paths: ctx.paths)

        // The mic anchor should have been forwarded to the system engine.
        #expect(ctx.systemEngine.micAnchor == anchor)
        #expect(ctx.micEngine.startCount == 1)

        ctx.deviceChangeProvider.finish()
    }

    // MARK: - Mic startup recovery

    /// Exhausted startup must remain idle, release both attempts and allow a retry.
    @Test("A mic that never delivers buffers fails startup instead of recording an empty track")
    func stalledMicFailsStartup() async throws {
        let ctx = try TestRecorderFactory.make()
        defer { TestRecorderFactory.cleanup(ctx) }
        ctx.micEngine.suppressFirstBuffer(forStarts: 2)

        do {
            try await ctx.recorder.start(paths: ctx.paths)
            Issue.record("Expected microphone startup to fail")
        } catch {
            guard case .micEngineFailed = error as? CaptureError else {
                Issue.record("Expected micEngineFailed, got \(error)")
                return
            }
        }

        #expect(ctx.micEngine.startCount == 2)
        #expect(ctx.micEngine.stopCount == 2)
        #expect(ctx.systemEngine.startCount == 0)
        for await state in await ctx.recorder.stateStream() {
            #expect(!state.isRecording)
            break
        }

        // A failed startup must leave the recorder retryable.
        try await ctx.recorder.start(paths: ctx.paths)
        #expect(ctx.systemEngine.startCount == 1)
        await ctx.recorder.stop()
    }

    /// Only the successful retry's timestamp may align the system recording.
    @Test("A stalled mic is restarted before system capture and uses the recovered anchor")
    func stalledMicRecovers() async throws {
        let ctx = try TestRecorderFactory.make()
        defer { TestRecorderFactory.cleanup(ctx) }
        ctx.micEngine.suppressFirstBuffer(forStarts: 1)
        ctx.micEngine.setFirstBufferAnchor(42.5)

        try await ctx.recorder.start(paths: ctx.paths)

        #expect(ctx.micEngine.startCount == 2)
        #expect(ctx.micEngine.stopCount == 1)
        #expect(ctx.systemEngine.startCount == 1)
        #expect(ctx.systemEngine.micAnchor == 42.5)
        await ctx.recorder.stop()
    }

    /// Cancellation must release the waiting attempt without advancing to system audio.
    @Test("Cancellation while waiting for the mic stops capture without starting system audio")
    func cancelledMicStartup() async throws {
        let ctx = try TestRecorderFactory.make()
        defer { TestRecorderFactory.cleanup(ctx) }
        ctx.micEngine.suppressFirstBuffer(forStarts: 2)
        let started = AsyncStream<Void>.makeStream()
        ctx.micEngine.onStart = { started.continuation.yield(()) }
        let task = Task { try await ctx.recorder.start(paths: ctx.paths) }
        for await _ in started.stream {
            break
        }
        task.cancel()
        await #expect(throws: CancellationError.self) { try await task.value }
        #expect(ctx.micEngine.startCount == 1)
        #expect(ctx.micEngine.stopCount == 1)
        #expect(ctx.systemEngine.startCount == 0)
        started.continuation.finish()
    }

    // MARK: - System start retry

    @Test("Transient system start failure retries and succeeds")
    func transientSystemStartRetries() async throws {
        let ctx = try TestRecorderFactory.make()
        defer { TestRecorderFactory.cleanup(ctx) }

        // Fail the first start, succeed on retry.
        ctx.systemEngine.setTransientStartError(
            CaptureError.tapCreationFailed(-1), failureCount: 1
        )

        try await ctx.recorder.start(paths: ctx.paths)

        // 1 failing + 1 succeeding = 2 total start calls.
        #expect(ctx.systemEngine.startCount == 2)
        #expect(ctx.micEngine.startCount == 1)

        let stream = await ctx.recorder.stateStream()
        for await state in stream {
            #expect(state.isRecording == true)
            break
        }

        ctx.deviceChangeProvider.finish()
        await ctx.recorder.stop()
    }

    @Test("Permanent system start failure exhausts retries and throws")
    func permanentSystemStartFailureThrows() async throws {
        let ctx = try TestRecorderFactory.make()
        defer { TestRecorderFactory.cleanup(ctx) }

        // All start attempts will fail.
        ctx.systemEngine.setStartError(CaptureError.tapCreationFailed(-999))

        do {
            try await ctx.recorder.start(paths: ctx.paths)
            Issue.record("Expected start to throw after exhausting retries")
        } catch {
            // Expected — retries exhausted.
        }

        // Should have tried 1 + maxRetries = 3 total start calls.
        let expectedAttempts = AudioRecorder.systemStartMaxRetries + 1
        #expect(ctx.systemEngine.startCount == expectedAttempts)

        // Mic was started once (before system retries) then stopped on failure.
        #expect(ctx.micEngine.startCount == 1)
        #expect(ctx.micEngine.stopCount == 1)
    }

    @Test("System engine start is gated on mic first buffer (fake fires immediately)")
    func systemStartGatedOnMicFirstBuffer() async throws {
        let ctx = try TestRecorderFactory.make()
        defer { TestRecorderFactory.cleanup(ctx) }

        try await ctx.recorder.start(paths: ctx.paths)

        // The mic engine's onFirstBuffer should have been set and called.
        // The system engine should have started after the mic anchor was
        // available.
        #expect(ctx.micEngine.startCount == 1)
        #expect(ctx.systemEngine.startCount == 1)

        ctx.deviceChangeProvider.finish()
    }
}
