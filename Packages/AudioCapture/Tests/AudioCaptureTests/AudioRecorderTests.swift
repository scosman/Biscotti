import AVFoundation
import Foundation
import Testing
@testable import AudioCapture

@Suite("AudioRecorderTests")
struct AudioRecorderTests {
    @Test("Start and stop lifecycle with fakes")
    func startAndStopLifecycle() async throws {
        let ctx = try TestRecorderFactory.make()
        defer { TestRecorderFactory.cleanup(ctx) }

        try await ctx.recorder.start(paths: ctx.paths)

        // isRecording should be true
        let stream = await ctx.recorder.stateStream()
        for await state in stream {
            #expect(state.isRecording == true)
            break
        }

        ctx.deviceChangeProvider.finish()
        await ctx.recorder.stop()

        // Engines were stopped.
        #expect(ctx.systemEngine.stopCount == 1)
        #expect(ctx.micEngine.stopCount == 1)
    }

    @Test("stop() when not recording is a no-op")
    func stopWhenNotRecordingIsNoOp() async throws {
        let ctx = try TestRecorderFactory.make()
        defer { TestRecorderFactory.cleanup(ctx) }

        // Never started -- stop should be a no-op, not throw.
        await ctx.recorder.stop()
        #expect(ctx.systemEngine.stopCount == 0)
    }

    @Test("stateStream emits updates with isRecording true")
    func stateStreamEmitsUpdates() async throws {
        let ctx = try TestRecorderFactory.make()
        defer { TestRecorderFactory.cleanup(ctx) }

        try await ctx.recorder.start(paths: ctx.paths)

        let stream = await ctx.recorder.stateStream()
        var receivedStates: [CaptureState] = []
        for await state in stream {
            receivedStates.append(state)
            if receivedStates.count >= 1 { break }
        }

        #expect(!receivedStates.isEmpty)
        #expect(receivedStates[0].isRecording == true)
        #expect(receivedStates[0].startTimestamp > 0)

        ctx.deviceChangeProvider.finish()
    }

    @Test("Idle state before start")
    func idleStateBeforeStart() async throws {
        let ctx = try TestRecorderFactory.make()
        defer { TestRecorderFactory.cleanup(ctx) }

        let stream = await ctx.recorder.stateStream()
        for await state in stream {
            #expect(state.isRecording == false)
            #expect(state.startTimestamp == 0)
            #expect(state.elapsed == 0)
            break
        }
    }

    @Test("CaptureState.idle has expected defaults")
    func captureStateIdle() {
        let idle = CaptureState.idle
        #expect(idle.isRecording == false)
        #expect(idle.elapsed == 0)
        #expect(idle.micLevel == 0)
        #expect(idle.systemLevel == 0)
        #expect(idle.startTimestamp == 0)
    }

    @Test("CapturePaths stores URLs correctly")
    func capturePathsStoresURLs() {
        let micAAC = URL(fileURLWithPath: "/tmp/mic.aac")
        let sysAAC = URL(fileURLWithPath: "/tmp/sys.aac")

        let paths = CapturePaths(
            micAAC: micAAC,
            systemAAC: sysAAC
        )

        #expect(paths.micAAC == micAAC)
        #expect(paths.systemAAC == sysAAC)
    }

    @Test("DeviceChangeEvent equality")
    func deviceChangeEventEquality() {
        #expect(DeviceChangeEvent.outputChanged == DeviceChangeEvent.outputChanged)
        #expect(DeviceChangeEvent.inputChanged == DeviceChangeEvent.inputChanged)
        #expect(DeviceChangeEvent.outputChanged != DeviceChangeEvent.inputChanged)
    }

    @Test("start() throws micPermissionDenied when denied")
    func startThrowsOnMicDenied() async throws {
        let ctx = try TestRecorderFactory.make(micAuthStatus: .denied)
        defer { TestRecorderFactory.cleanup(ctx) }

        do {
            try await ctx.recorder.start(paths: ctx.paths)
            Issue.record("Expected start to throw micPermissionDenied")
        } catch let error as CaptureError {
            #expect(error == .micPermissionDenied)
        }

        // Neither engine should have been started.
        #expect(ctx.systemEngine.startCount == 0)
        #expect(ctx.micEngine.startCount == 0)
    }

    @Test("start() proceeds when notDetermined and requestAccess grants")
    func startProceedsOnNotDeterminedGranted() async throws {
        let ctx = try TestRecorderFactory.make(micAuthStatus: .notDetermined, requestAccessResult: true)
        defer { TestRecorderFactory.cleanup(ctx) }

        // Should succeed — requestAccess returns true.
        try await ctx.recorder.start(paths: ctx.paths)

        #expect(ctx.systemEngine.startCount == 1)
        #expect(ctx.micEngine.startCount == 1)

        ctx.deviceChangeProvider.finish()
        await ctx.recorder.stop()
    }

    @Test("start() throws micPermissionDenied when notDetermined and requestAccess denies")
    func startThrowsOnNotDeterminedDenied() async throws {
        let ctx = try TestRecorderFactory.make(micAuthStatus: .notDetermined, requestAccessResult: false)
        defer { TestRecorderFactory.cleanup(ctx) }

        do {
            try await ctx.recorder.start(paths: ctx.paths)
            Issue.record("Expected start to throw micPermissionDenied")
        } catch let error as CaptureError {
            #expect(error == .micPermissionDenied)
        }

        // Neither engine should have been started.
        #expect(ctx.systemEngine.startCount == 0)
        #expect(ctx.micEngine.startCount == 0)
    }

    @Test("start() throws micPermissionDenied when restricted")
    func startThrowsOnMicRestricted() async throws {
        let ctx = try TestRecorderFactory.make(micAuthStatus: .restricted)
        defer { TestRecorderFactory.cleanup(ctx) }

        do {
            try await ctx.recorder.start(paths: ctx.paths)
            Issue.record("Expected start to throw micPermissionDenied")
        } catch let error as CaptureError {
            #expect(error == .micPermissionDenied)
        }

        // Neither engine should have been started.
        #expect(ctx.systemEngine.startCount == 0)
        #expect(ctx.micEngine.startCount == 0)
    }
}
