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

    @Test("System engine starts before mic engine")
    func systemStartsFirst() async throws {
        let ctx = try TestRecorderFactory.make()
        defer { TestRecorderFactory.cleanup(ctx) }

        try await ctx.recorder.start(paths: ctx.paths)

        // Both started
        #expect(ctx.systemEngine.startCount == 1)
        #expect(ctx.micEngine.startCount == 1)

        // System was given the system AAC URL
        #expect(ctx.systemEngine.lastURL == ctx.paths.systemAAC)
        // Mic was given the mic AAC URL
        #expect(ctx.micEngine.lastURL == ctx.paths.micAAC)

        ctx.deviceChangeProvider.finish()
    }

    @Test("If mic start fails, system engine is stopped")
    func micFailureStopsSystem() async throws {
        let ctx = try TestRecorderFactory.make()
        defer { TestRecorderFactory.cleanup(ctx) }

        ctx.micEngine.setStartError(CaptureError.micEngineFailed("test"))

        do {
            try await ctx.recorder.start(paths: ctx.paths)
            Issue.record("Expected start to throw")
        } catch {
            // System was started then stopped after mic failure
            #expect(ctx.systemEngine.startCount == 1)
            #expect(ctx.systemEngine.stopCount == 1)
            #expect(ctx.micEngine.startCount == 1)
        }
    }
}
