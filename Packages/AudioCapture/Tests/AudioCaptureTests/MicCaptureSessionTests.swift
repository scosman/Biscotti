import AudioToolbox
import AVFoundation
import Foundation
import Synchronization
import Testing
@testable import AudioCapture

@Suite("Mic capture callback ownership")
struct MicCaptureSessionTests {
    /// Reproduces a timed-out attempt delivering a callback after the retry has
    /// opened the same path. Neither the retried file nor either anchor may change.
    @Test("A late callback from a stopped attempt cannot write into or confirm its retry")
    func lateAttemptCallback() throws {
        let url = temporaryRecording()
        defer { try? FileManager.default.removeItem(at: url) }
        let oldAnchors = Mutex<[Double]>([])
        let retryAnchors = Mutex<[Double]>([])
        let old = try MicCaptureSession(url: url, encoder: .voice) { anchor in
            oldAnchors.withLock { $0.append(anchor) }
        }
        let lateCallback = old.makeTapHandler()
        old.close()

        let retry = try MicCaptureSession(url: url, encoder: .voice) { anchor in
            retryAnchors.withLock { $0.append(anchor) }
        }
        defer { retry.close() }
        _ = retry.makeTapHandler()
        try lateCallback(toneBuffer(), timestamp(seconds: 1))

        #expect(!retry.hasDeliveredBuffer)
        #expect(oldAnchors.withLock { $0.isEmpty })
        #expect(retryAnchors.withLock { $0.isEmpty })
        // Finalize the encoder before inspecting bytes: buffering must not hide
        // an incorrectly accepted write from the retired attempt.
        retry.close()
        #expect(try Data(contentsOf: url).isEmpty)
    }

    /// Exercises tap replacement on the same session, matching the startup
    /// restart path that keeps VPIO and the recording file alive.
    @Test("A replaced tap cannot write audio, settle the new graph or consume its anchor")
    func replacedTapCallback() throws {
        let url = temporaryRecording()
        defer { try? FileManager.default.removeItem(at: url) }
        let anchors = Mutex<[Double]>([])
        let session = try MicCaptureSession(url: url, encoder: .voice) { anchor in
            anchors.withLock { $0.append(anchor) }
        }
        defer { session.close() }
        let oldTap = session.makeTapHandler()
        session.invalidateTap()
        _ = session.makeTapHandler()
        try oldTap(toneBuffer(), timestamp(seconds: 1))

        #expect(!session.hasDeliveredBuffer)
        #expect(anchors.withLock { $0.isEmpty })
        session.close()
        #expect(try Data(contentsOf: url).isEmpty)
    }

    /// Confirms current audio still starts capture after stale callbacks, and
    /// that reconnect preserves the original anchor and appends to the same file.
    @Test("Only the current tap writes audio and the session anchor survives tap replacement")
    func currentTapPreservesSession() throws {
        let url = temporaryRecording()
        defer { try? FileManager.default.removeItem(at: url) }
        let anchors = Mutex<[Double]>([])
        let session = try MicCaptureSession(url: url, encoder: .voice) { anchor in
            anchors.withLock { $0.append(anchor) }
        }
        defer { session.close() }
        let buffer = try toneBuffer()
        let oldTap = session.makeTapHandler()
        let firstTap = session.makeTapHandler()
        oldTap(buffer, timestamp(seconds: 1))
        firstTap(buffer, timestamp(seconds: 2))
        #expect(session.hasDeliveredBuffer)
        #expect(anchors.withLock { $0 } == [2])

        session.invalidateTap()
        let nextTap = session.makeTapHandler()
        firstTap(buffer, timestamp(seconds: 3))
        #expect(!session.hasDeliveredBuffer)
        nextTap(buffer, timestamp(seconds: 4))
        #expect(session.hasDeliveredBuffer)
        #expect(anchors.withLock { $0 } == [2])
        session.close()

        let sampleRate = EncoderSettings.voice.processingFormat.sampleRate
        let audio = try AVAudioFile(forReading: url)
        // Two accepted buffers plus gap-fill silence between t=2 and t=4.
        // The gap = (4 - 2 - bufferDuration) seconds of silence is inserted.
        let bufferDuration = Double(buffer.frameLength) / sampleRate
        let expectedGap = 4.0 - 2.0 - bufferDuration
        let expectedFrames = Double(buffer.frameLength) * 2 + expectedGap * sampleRate
        #expect(audio.length >= AVAudioFramePosition(buffer.frameLength) * 2)
        // Allow AAC codec padding (~2048 frames).
        #expect(Double(audio.length) < expectedFrames + 3000)
        let contents = try Data(contentsOf: url)
        nextTap(buffer, timestamp(seconds: 5))
        #expect(try Data(contentsOf: url) == contents)
        #expect(anchors.withLock { $0 } == [2])
    }

    /// An empty callback must not satisfy startup or prevent later real audio.
    @Test("Empty buffers do not settle the tap or fire its first-buffer callback")
    func emptyBufferDoesNotConfirmStartup() throws {
        let url = temporaryRecording()
        defer { try? FileManager.default.removeItem(at: url) }
        let anchors = Mutex<[Double]>([])
        let session = try MicCaptureSession(url: url, encoder: .voice) { anchor in
            anchors.withLock { $0.append(anchor) }
        }
        defer { session.close() }
        let tap = session.makeTapHandler()
        let buffer = try toneBuffer()
        buffer.frameLength = 0
        tap(buffer, timestamp(seconds: 1))
        #expect(!session.hasDeliveredBuffer)
        #expect(anchors.withLock { $0.isEmpty })
        try tap(toneBuffer(), timestamp(seconds: 2))
        #expect(anchors.withLock { $0 } == [2])
    }

    /// Writes two buffers with a 2-second gap between them. Asserts the
    /// decoded file duration is approximately bufferDuration * 2 + gapDuration,
    /// confirming that the silence fill preserved wall-clock alignment.
    @Test("Gap between buffers is filled with silence to preserve track alignment")
    func gapFilledWithSilence() throws {
        let url = temporaryRecording()
        defer { try? FileManager.default.removeItem(at: url) }
        let session = try MicCaptureSession(url: url, encoder: .voice, onFirstBuffer: nil)
        defer { session.close() }
        let tap = session.makeTapHandler()
        let buffer = try toneBuffer()

        let sampleRate = EncoderSettings.voice.processingFormat.sampleRate
        let bufferDurationSec = Double(buffer.frameLength) / sampleRate

        // First buffer at t=1 s.
        tap(buffer, timestamp(seconds: 1))
        #expect(session.hasDeliveredBuffer)

        // Second buffer at t=1 + bufferDuration + 2 s gap.
        let secondTimeSec = 1.0 + bufferDurationSec + 2.0
        let secondTimeNanos = UInt64(secondTimeSec * 1_000_000_000)
        let secondTimestamp = AVAudioTime(hostTime: AudioConvertNanosToHostTime(secondTimeNanos))
        tap(buffer, secondTimestamp)

        session.close()

        // The file should contain: buffer1 + 2 s silence + buffer2.
        let audio = try AVAudioFile(forReading: url)
        let fileDurationSec = Double(audio.length) / audio.processingFormat.sampleRate
        let expectedDurationSec = bufferDurationSec * 2 + 2.0

        // AAC codec adds padding (~2048 frames = ~0.085 s at 24 kHz), so
        // allow a tolerance of 0.15 s.
        #expect(abs(fileDurationSec - expectedDurationSec) < 0.15,
                "File duration \(fileDurationSec)s should be close to \(expectedDurationSec)s")
    }

    /// A gap below the jitter threshold must not produce silence fill.
    @Test("Small jitter gap does not trigger silence fill")
    func jitterGapNotFilled() throws {
        let url = temporaryRecording()
        defer { try? FileManager.default.removeItem(at: url) }
        let session = try MicCaptureSession(url: url, encoder: .voice, onFirstBuffer: nil)
        defer { session.close() }
        let tap = session.makeTapHandler()
        let buffer = try toneBuffer()

        let sampleRate = EncoderSettings.voice.processingFormat.sampleRate
        let bufferDurationSec = Double(buffer.frameLength) / sampleRate

        // First buffer at t=1 s.
        tap(buffer, timestamp(seconds: 1))

        // Second buffer 1 ms after expected (jitter, well below 5 ms threshold).
        let secondTimeSec = 1.0 + bufferDurationSec + 0.001
        let secondTimeNanos = UInt64(secondTimeSec * 1_000_000_000)
        let secondTimestamp = AVAudioTime(hostTime: AudioConvertNanosToHostTime(secondTimeNanos))
        tap(buffer, secondTimestamp)

        session.close()

        // The file should contain only two buffers worth of audio (no silence).
        let audio = try AVAudioFile(forReading: url)
        let fileDurationSec = Double(audio.length) / audio.processingFormat.sampleRate
        let expectedDurationSec = bufferDurationSec * 2

        // With only 1 ms jitter (below threshold), no silence should be added.
        // AAC adds some padding, so allow tolerance but it should be much less
        // than 2 s worth of silence.
        #expect(fileDurationSec < expectedDurationSec + 0.5,
                "File duration \(fileDurationSec)s should be close to \(expectedDurationSec)s without silence fill")
    }

    /// Gap fill spans a tap replacement (reconnect). The session keeps the
    /// expected-next timestamp across taps so the gap is detected and filled.
    @Test("Gap fill works across tap replacement (reconnect)")
    func gapFillAcrossReconnect() throws {
        let url = temporaryRecording()
        defer { try? FileManager.default.removeItem(at: url) }
        let session = try MicCaptureSession(url: url, encoder: .voice, onFirstBuffer: nil)
        defer { session.close() }
        let buffer = try toneBuffer()

        let sampleRate = EncoderSettings.voice.processingFormat.sampleRate
        let bufferDurationSec = Double(buffer.frameLength) / sampleRate

        // First tap: write one buffer at t=1 s.
        let tap1 = session.makeTapHandler()
        tap1(buffer, timestamp(seconds: 1))

        // Simulate reconnect: invalidate + new tap.
        session.invalidateTap()
        let tap2 = session.makeTapHandler()

        // Second buffer at t=1 + bufferDuration + 1.5 s gap, via new tap.
        let secondTimeSec = 1.0 + bufferDurationSec + 1.5
        let secondTimeNanos = UInt64(secondTimeSec * 1_000_000_000)
        let secondTimestamp = AVAudioTime(hostTime: AudioConvertNanosToHostTime(secondTimeNanos))
        tap2(buffer, secondTimestamp)

        session.close()

        let audio = try AVAudioFile(forReading: url)
        let fileDurationSec = Double(audio.length) / audio.processingFormat.sampleRate
        let expectedDurationSec = bufferDurationSec * 2 + 1.5

        #expect(abs(fileDurationSec - expectedDurationSec) < 0.15,
                "File duration \(fileDurationSec)s should be close to \(expectedDurationSec)s after reconnect gap fill")
    }

    /// Uses a unique file without activating a microphone or requiring permission.
    private func temporaryRecording() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("mic-session-\(UUID()).aac")
    }

    /// Supplies enough nonzero PCM frames to exercise real AAC encoding and flush.
    private func toneBuffer() throws -> AVAudioPCMBuffer {
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: EncoderSettings.voice.processingFormat, frameCapacity: 8192))
        buffer.frameLength = buffer.frameCapacity
        let samples = try #require(buffer.floatChannelData?[0])
        for frame in 0 ..< Int(buffer.frameLength) {
            samples[frame] = 0.2 * sin(Float(frame) * 0.1)
        }
        return buffer
    }

    /// Makes deterministic host-clock anchors independently of wall-clock time.
    private func timestamp(seconds: UInt64) -> AVAudioTime {
        AVAudioTime(hostTime: AudioConvertNanosToHostTime(seconds * 1_000_000_000))
    }
}
