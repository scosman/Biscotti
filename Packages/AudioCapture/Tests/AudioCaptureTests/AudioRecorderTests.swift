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

        // Write synthetic CAF files so RecordingFileManager has something to encode.
        try createTestCAF(at: ctx.paths.micCAF)
        try createTestCAF(at: ctx.paths.systemCAF)

        try await ctx.recorder.start(paths: ctx.paths)

        // isRecording should be true
        let stream = await ctx.recorder.stateStream()
        for await state in stream {
            #expect(state.isRecording == true)
            break
        }

        ctx.deviceChangeProvider.finish()
        let result = try await ctx.recorder.stop()

        // Output files should exist.
        #expect(result != nil)
        #expect(result?.mic != nil)
        #expect(result?.system != nil)
        #expect(try FileManager.default.fileExists(atPath: #require(result?.mic?.path)))
        #expect(try FileManager.default.fileExists(atPath: #require(result?.system?.path)))

        // Engines were stopped.
        #expect(ctx.systemEngine.stopCount == 1)
        #expect(ctx.micEngine.stopCount == 1)
    }

    @Test("stop() when not recording returns nil (no-op)")
    func stopWhenNotRecordingIsNoOp() async throws {
        let ctx = try TestRecorderFactory.make()
        defer { TestRecorderFactory.cleanup(ctx) }

        // Never started -- stop should be a no-op, not throw.
        let result = try await ctx.recorder.stop()
        #expect(result == nil)
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
        let micCAF = URL(fileURLWithPath: "/tmp/mic.caf")
        let sysCAF = URL(fileURLWithPath: "/tmp/sys.caf")
        let micOut = URL(fileURLWithPath: "/tmp/mic.m4a")
        let sysOut = URL(fileURLWithPath: "/tmp/sys.m4a")

        let paths = CapturePaths(
            micCAF: micCAF,
            systemCAF: sysCAF,
            micOutput: micOut,
            systemOutput: sysOut
        )

        #expect(paths.micCAF == micCAF)
        #expect(paths.systemCAF == sysCAF)
        #expect(paths.micOutput == micOut)
        #expect(paths.systemOutput == sysOut)
    }

    @Test("DeviceChangeEvent equality")
    func deviceChangeEventEquality() {
        #expect(DeviceChangeEvent.outputChanged == DeviceChangeEvent.outputChanged)
        #expect(DeviceChangeEvent.inputChanged == DeviceChangeEvent.inputChanged)
        #expect(DeviceChangeEvent.outputChanged != DeviceChangeEvent.inputChanged)
    }

    // MARK: - Helpers

    private func createTestCAF(at url: URL, sampleRate: Double = 24000, duration: Double = 0.5) throws {
        let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 1)
        // swiftlint:disable:next force_unwrapping
        let file = try AVAudioFile(forWriting: url, settings: format!.settings)
        let frameCount = AVAudioFrameCount(sampleRate * duration)
        // swiftlint:disable:next force_unwrapping
        let buffer = AVAudioPCMBuffer(pcmFormat: format!, frameCapacity: frameCount)!
        buffer.frameLength = frameCount
        // swiftlint:disable:next force_unwrapping
        let samples = buffer.floatChannelData![0]
        for idx in 0 ..< Int(frameCount) {
            samples[idx] = sinf(Float(idx) * 2.0 * .pi * 440.0 / Float(sampleRate))
        }
        try file.write(from: buffer)
    }
}
