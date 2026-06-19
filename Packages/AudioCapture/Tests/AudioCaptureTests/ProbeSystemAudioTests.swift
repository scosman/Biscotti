import Foundation
import Testing
@testable import AudioCapture

@Suite("AudioRecorder — probeSystemAudioWithTone")
struct ProbeSystemAudioTests {
    @Test("probe returns true immediately when non-zero audio observed")
    func probeReturnsTrueWhenObserved() async throws {
        let ctx = try TestRecorderFactory.make(observedNonZero: false)
        defer { TestRecorderFactory.cleanup(ctx) }

        // Simulate audio arriving after the system engine starts (mirrors
        // real behavior: reset clears the flag, then ingestSamples sets it
        // once audio flows through the tap).
        let checker = ctx.permissionChecker
        ctx.systemEngine.onStart = { checker.setObservedNonZero(true) }

        let result = await ctx.recorder.probeSystemAudioWithTone(
            timeout: .seconds(1)
        )

        #expect(result == true)
        // System engine was started and stopped for the probe.
        #expect(ctx.systemEngine.startCount == 1)
        #expect(ctx.systemEngine.stopCount == 1)
    }

    @Test("probe returns false on timeout when no audio observed")
    func probeReturnsFalseOnTimeout() async throws {
        let ctx = try TestRecorderFactory.make(observedNonZero: false)
        defer { TestRecorderFactory.cleanup(ctx) }

        let result = await ctx.recorder.probeSystemAudioWithTone(
            timeout: .milliseconds(200)
        )

        #expect(result == false)
        // System engine was still started and stopped for the probe.
        #expect(ctx.systemEngine.startCount == 1)
        #expect(ctx.systemEngine.stopCount == 1)
    }

    @Test("probe returns false when system engine fails to start")
    func probeReturnsFalseWhenEngineStartFails() async throws {
        let ctx = try TestRecorderFactory.make(observedNonZero: false)
        defer { TestRecorderFactory.cleanup(ctx) }

        ctx.systemEngine.setStartError(
            CaptureError.probeFailed("test failure")
        )

        let result = await ctx.recorder.probeSystemAudioWithTone(
            timeout: .seconds(1)
        )

        #expect(result == false)
    }

    @Test("observedSystemAudio reflects checker state")
    func observedSystemAudioReflectsChecker() async throws {
        let ctx = try TestRecorderFactory.make(observedNonZero: false)
        defer { TestRecorderFactory.cleanup(ctx) }

        let initial = await ctx.recorder.observedSystemAudio()
        #expect(initial == false)

        ctx.permissionChecker.setObservedNonZero(true)
        let updated = await ctx.recorder.observedSystemAudio()
        #expect(updated == true)
    }

    @Test("probe always stops engine even on success")
    func probeAlwaysStopsEngine() async throws {
        let ctx = try TestRecorderFactory.make(observedNonZero: false)
        defer { TestRecorderFactory.cleanup(ctx) }

        // Simulate audio arriving after engine starts.
        let checker = ctx.permissionChecker
        ctx.systemEngine.onStart = { checker.setObservedNonZero(true) }

        _ = await ctx.recorder.probeSystemAudioWithTone(
            timeout: .seconds(1)
        )

        // Verify engine was stopped (cleanup happens even on success).
        #expect(ctx.systemEngine.stopCount == 1)
    }
}
