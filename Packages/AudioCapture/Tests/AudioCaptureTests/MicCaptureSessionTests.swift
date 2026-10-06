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

        let audio = try AVAudioFile(forReading: url)
        // Two accepted buffers must survive reconnect; AAC may add codec padding.
        #expect(audio.length >= AVAudioFramePosition(buffer.frameLength) * 2)
        #expect(audio.length < AVAudioFramePosition(buffer.frameLength) * 3)
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
