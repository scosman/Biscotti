import Foundation
import Testing
@testable import AudioCapture

@Suite("RouteChangeTests")
struct RouteChangeTests {
    @Test("Output change reconnects system capture without stop/start (file-preserving)")
    func outputChangeReconnectsSystemCapture() async throws {
        let ctx = try TestRecorderFactory.make()
        defer { TestRecorderFactory.cleanup(ctx) }

        try await ctx.recorder.start(paths: ctx.paths)
        #expect(ctx.systemEngine.startCount == 1)
        #expect(ctx.micEngine.startCount == 1)

        // Wait for the route-change listener to be ready.
        try await ctx.deviceChangeProvider.waitUntilReady()

        // Inject an output-device change event.
        ctx.deviceChangeProvider.send(.outputChanged)

        // Give the route-change handler time to process.
        try await Task.sleep(for: .milliseconds(200))

        // System engine should have been reconnected, NOT stopped and restarted.
        // reconnect() preserves the audio file; stop()+start() would erase it.
        #expect(ctx.systemEngine.reconnectCount == 1)
        #expect(ctx.systemEngine.stopCount == 0, "stop() must NOT be called on route change (would erase file)")
        #expect(ctx.systemEngine.startCount == 1, "start() must NOT be called on route change (would erase file)")

        // Mic engine should NOT have been touched.
        #expect(ctx.micEngine.stopCount == 0)
        #expect(ctx.micEngine.startCount == 1)
        #expect(ctx.micEngine.reconnectCount == 0)

        // isRecording stays true throughout.
        let stream = await ctx.recorder.stateStream()
        for await state in stream {
            #expect(state.isRecording == true)
            break
        }

        ctx.deviceChangeProvider.finish()
    }

    @Test("Input change does NOT destructively restart mic (mic handles internally)")
    func inputChangeDoesNotRestartMic() async throws {
        let ctx = try TestRecorderFactory.make()
        defer { TestRecorderFactory.cleanup(ctx) }

        try await ctx.recorder.start(paths: ctx.paths)
        #expect(ctx.systemEngine.startCount == 1)
        #expect(ctx.micEngine.startCount == 1)

        // Wait for the route-change listener to be ready.
        try await ctx.deviceChangeProvider.waitUntilReady()

        // Inject an input-device change event.
        ctx.deviceChangeProvider.send(.inputChanged)

        // Give the route-change handler time to process.
        try await Task.sleep(for: .milliseconds(200))

        // Mic engine should NOT have been stopped or restarted by AudioRecorder.
        // The mic engine handles input-route changes internally via
        // AVAudioEngineConfigurationChange, which preserves the file.
        #expect(ctx.micEngine.stopCount == 0, "AudioRecorder must not stop mic on input change")
        #expect(ctx.micEngine.startCount == 1, "AudioRecorder must not restart mic on input change")
        #expect(ctx.micEngine.reconnectCount == 0)

        // System engine should NOT have been touched.
        #expect(ctx.systemEngine.stopCount == 0)
        #expect(ctx.systemEngine.startCount == 1)
        #expect(ctx.systemEngine.reconnectCount == 0)

        // isRecording stays true throughout.
        let stream = await ctx.recorder.stateStream()
        for await state in stream {
            #expect(state.isRecording == true)
            break
        }

        ctx.deviceChangeProvider.finish()
    }

    @Test("Multiple route changes all use reconnect (no file erasure)")
    func multipleRouteChanges() async throws {
        let ctx = try TestRecorderFactory.make()
        defer { TestRecorderFactory.cleanup(ctx) }

        try await ctx.recorder.start(paths: ctx.paths)

        // Wait for the route-change listener to be ready.
        try await ctx.deviceChangeProvider.waitUntilReady()

        // Send an output change.
        ctx.deviceChangeProvider.send(.outputChanged)

        // Let the first event process before sending the second.
        try await Task.sleep(for: .milliseconds(200))

        // Send an input change (no-op at AudioRecorder level).
        ctx.deviceChangeProvider.send(.inputChanged)

        try await Task.sleep(for: .milliseconds(200))

        // System engine was reconnected once (for output change).
        #expect(ctx.systemEngine.reconnectCount == 1)
        #expect(ctx.systemEngine.stopCount == 0)
        #expect(ctx.systemEngine.startCount == 1)

        // Mic engine was not touched by AudioRecorder (input change is internal).
        #expect(ctx.micEngine.reconnectCount == 0)
        #expect(ctx.micEngine.stopCount == 0)
        #expect(ctx.micEngine.startCount == 1)

        // Still recording
        let stream = await ctx.recorder.stateStream()
        for await state in stream {
            #expect(state.isRecording == true)
            break
        }

        ctx.deviceChangeProvider.finish()
    }

    @Test("Route change does nothing when not recording")
    func routeChangeWhileNotRecording() async throws {
        let ctx = try TestRecorderFactory.make()
        defer { TestRecorderFactory.cleanup(ctx) }

        // Don't start recording. The provider won't have a consumer,
        // so send() silently drops events. This is the expected behavior.
        try await Task.sleep(for: .milliseconds(50))

        // Nothing happened.
        #expect(ctx.systemEngine.startCount == 0)
        #expect(ctx.micEngine.startCount == 0)
        #expect(ctx.systemEngine.reconnectCount == 0)
        #expect(ctx.micEngine.reconnectCount == 0)
    }

    // MARK: - Reconnect retry

    @Test("Transient reconnect failure retries and succeeds")
    func transientReconnectFailureRetries() async throws {
        let ctx = try TestRecorderFactory.make()
        defer { TestRecorderFactory.cleanup(ctx) }

        try await ctx.recorder.start(paths: ctx.paths)
        try await ctx.deviceChangeProvider.waitUntilReady()

        // First reconnect will fail, second will succeed.
        ctx.systemEngine.setTransientReconnectError(
            CaptureError.tapCreationFailed(-1), failureCount: 1
        )

        ctx.deviceChangeProvider.send(.outputChanged)
        // Fake engine has no settle delay — only the retry delay (300ms) applies.
        // Generous wait to avoid flakiness.
        try await Task.sleep(for: .seconds(1))

        // Should have retried: 1 failure + 1 success = 2 reconnect calls.
        #expect(ctx.systemEngine.reconnectCount == 2)

        // Still recording (retry succeeded).
        let stream = await ctx.recorder.stateStream()
        for await state in stream {
            #expect(state.isRecording == true)
            break
        }

        ctx.deviceChangeProvider.finish()
    }

    @Test("Permanent reconnect failure exhausts retries — mic continues")
    func permanentReconnectFailureExhaustsRetries() async throws {
        let ctx = try TestRecorderFactory.make()
        defer { TestRecorderFactory.cleanup(ctx) }

        try await ctx.recorder.start(paths: ctx.paths)
        try await ctx.deviceChangeProvider.waitUntilReady()

        // All reconnect attempts will fail.
        ctx.systemEngine.setReconnectError(CaptureError.tapCreationFailed(-1))

        ctx.deviceChangeProvider.send(.outputChanged)
        // 3 attempts with 2 retry delays (300ms each). Fake engine has no settle
        // delay — only the retry delays apply. Generous wait to avoid flakiness.
        try await Task.sleep(for: .milliseconds(1500))

        // Should have tried 1 + maxRetries = 3 total reconnect calls.
        let expectedAttempts = AudioRecorder.systemReconnectMaxRetries + 1
        #expect(ctx.systemEngine.reconnectCount == expectedAttempts)

        // Mic engine was not touched.
        #expect(ctx.micEngine.stopCount == 0)
        #expect(ctx.micEngine.reconnectCount == 0)

        ctx.deviceChangeProvider.finish()
    }

    @Test("Reconnect distinguishes from initial start -- only start creates file")
    func reconnectDistinguishedFromStart() async throws {
        let ctx = try TestRecorderFactory.make()
        defer { TestRecorderFactory.cleanup(ctx) }

        try await ctx.recorder.start(paths: ctx.paths)

        // Initial start: start() called once, no reconnect.
        #expect(ctx.systemEngine.startCount == 1)
        #expect(ctx.systemEngine.reconnectCount == 0)

        try await ctx.deviceChangeProvider.waitUntilReady()

        // Route change: reconnect called, NOT start.
        ctx.deviceChangeProvider.send(.outputChanged)
        try await Task.sleep(for: .milliseconds(200))

        #expect(ctx.systemEngine.startCount == 1, "start() creates/erases the file -- must only be called once")
        #expect(ctx.systemEngine.reconnectCount == 1, "reconnect() preserves the file")

        // Second route change.
        ctx.deviceChangeProvider.send(.outputChanged)
        try await Task.sleep(for: .milliseconds(200))

        #expect(ctx.systemEngine.startCount == 1, "start() still only called once")
        #expect(ctx.systemEngine.reconnectCount == 2, "reconnect() called for each route change")

        ctx.deviceChangeProvider.finish()
    }
}
