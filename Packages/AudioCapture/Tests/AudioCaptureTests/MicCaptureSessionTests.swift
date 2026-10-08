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
        session.flushWriter()
        #expect(anchors.withLock { $0 } == [2])

        session.invalidateTap()
        let nextTap = session.makeTapHandler()
        firstTap(buffer, timestamp(seconds: 3))
        #expect(!session.hasDeliveredBuffer)
        nextTap(buffer, timestamp(seconds: 4))
        #expect(session.hasDeliveredBuffer)
        session.flushWriter()
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
        session.flushWriter()
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

        // Second buffer 1 ms after expected (jitter, well below 100 ms threshold).
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

    // MARK: - Helpers

    /// Uses a unique file without activating a microphone or requiring permission.
    private func temporaryRecording() -> URL {
        MicCaptureTestHelpers.temporaryRecording()
    }

    /// Supplies enough nonzero PCM frames to exercise real AAC encoding and flush.
    private func toneBuffer() throws -> AVAudioPCMBuffer {
        try MicCaptureTestHelpers.toneBuffer()
    }

    /// Makes deterministic host-clock anchors independently of wall-clock time.
    private func timestamp(seconds: UInt64) -> AVAudioTime {
        MicCaptureTestHelpers.timestamp(seconds: seconds)
    }
}

// MARK: - Resampling regression tests (48 kHz → 24 kHz converter path)

@Suite("Mic capture resampling gap fill")
struct MicCaptureResamplingTests {
    /// Sends a continuous run of 48 kHz mono buffers (realistic tap sizes,
    /// contiguous host times) through the converter path into a 24 kHz AAC
    /// file. Asserts zero gap fills and a file duration matching the total
    /// host-time span within AAC priming/padding tolerance.
    @Test("Continuous 48 kHz buffers produce no false gap fills")
    func continuousResampledBuffersNoGapFill() throws {
        let url = MicCaptureTestHelpers.temporaryRecording()
        defer { try? FileManager.default.removeItem(at: url) }
        let session = try MicCaptureSession(url: url, encoder: .voice, onFirstBuffer: nil)
        defer { session.close() }
        let tap = session.makeTapHandler()

        let sourceRate = 48000.0
        let bufferFrames: AVAudioFrameCount = 4800 // 100 ms at 48 kHz
        let bufferCount = 50 // 5 s of audio
        var hostNanos: UInt64 = 1_000_000_000 // start at t=1 s

        for _ in 0 ..< bufferCount {
            let buf = try MicCaptureTestHelpers.toneBuffer(sampleRate: sourceRate, frameCount: bufferFrames)
            let time = AVAudioTime(hostTime: AudioConvertNanosToHostTime(hostNanos))
            tap(buf, time)
            let durationNanos = UInt64(Double(bufferFrames) / sourceRate * 1_000_000_000)
            hostNanos += durationNanos
        }

        session.close()

        let totalInputDurationSec = Double(bufferFrames) * Double(bufferCount) / sourceRate
        let outputRate = EncoderSettings.voice.processingFormat.sampleRate
        let audio = try AVAudioFile(forReading: url)
        let fileDurationSec = Double(audio.length) / outputRate

        // File duration should closely match the input span. AAC padding
        // adds ~2048 frames = ~0.085 s at 24 kHz. Allow 0.15 s tolerance.
        #expect(abs(fileDurationSec - totalInputDurationSec) < 0.15,
                "File \(fileDurationSec)s vs expected \(totalInputDurationSec)s — false gap fills inflated the file")
    }

    /// Sends 48 kHz buffers with a real multi-second gap and confirms the
    /// gap is still filled with silence through the converter path.
    @Test("Real gap is filled with silence through the 48 kHz converter path")
    func realGapFilledThroughConverter() throws {
        let url = MicCaptureTestHelpers.temporaryRecording()
        defer { try? FileManager.default.removeItem(at: url) }
        let session = try MicCaptureSession(url: url, encoder: .voice, onFirstBuffer: nil)
        defer { session.close() }
        let tap = session.makeTapHandler()

        let sourceRate = 48000.0
        let bufferFrames: AVAudioFrameCount = 4800 // 100 ms at 48 kHz
        let bufferDurationSec = Double(bufferFrames) / sourceRate
        let gapSeconds = 2.5

        let buf1 = try MicCaptureTestHelpers.toneBuffer(sampleRate: sourceRate, frameCount: bufferFrames)
        tap(buf1, MicCaptureTestHelpers.timestampNanos(1_000_000_000))

        let secondNanos = UInt64((1.0 + bufferDurationSec + gapSeconds) * 1_000_000_000)
        let buf2 = try MicCaptureTestHelpers.toneBuffer(sampleRate: sourceRate, frameCount: bufferFrames)
        tap(buf2, MicCaptureTestHelpers.timestampNanos(secondNanos))

        session.close()

        let outputRate = EncoderSettings.voice.processingFormat.sampleRate
        let audio = try AVAudioFile(forReading: url)
        let fileDurationSec = Double(audio.length) / outputRate
        let expectedDurationSec = bufferDurationSec * 2 + gapSeconds

        #expect(abs(fileDurationSec - expectedDurationSec) < 0.15,
                "File \(fileDurationSec)s vs expected \(expectedDurationSec)s — gap fill missing")
    }

    /// Sends 48 kHz buffers with a real gap that spans a tap replacement
    /// (reconnect). Confirms the gap is filled correctly.
    @Test("Real gap across reconnect is filled through the converter path")
    func realGapAcrossReconnectThroughConverter() throws {
        let url = MicCaptureTestHelpers.temporaryRecording()
        defer { try? FileManager.default.removeItem(at: url) }
        let session = try MicCaptureSession(url: url, encoder: .voice, onFirstBuffer: nil)
        defer { session.close() }

        let sourceRate = 48000.0
        let bufferFrames: AVAudioFrameCount = 4800
        let bufferDurationSec = Double(bufferFrames) / sourceRate
        let gapSeconds = 1.5

        let tap1 = session.makeTapHandler()
        try tap1(MicCaptureTestHelpers.toneBuffer(sampleRate: sourceRate, frameCount: bufferFrames),
                 MicCaptureTestHelpers.timestampNanos(1_000_000_000))

        session.invalidateTap()
        let tap2 = session.makeTapHandler()

        let secondNanos = UInt64((1.0 + bufferDurationSec + gapSeconds) * 1_000_000_000)
        try tap2(MicCaptureTestHelpers.toneBuffer(sampleRate: sourceRate, frameCount: bufferFrames),
                 MicCaptureTestHelpers.timestampNanos(secondNanos))

        session.close()

        let outputRate = EncoderSettings.voice.processingFormat.sampleRate
        let audio = try AVAudioFile(forReading: url)
        let fileDurationSec = Double(audio.length) / outputRate
        let expectedDurationSec = bufferDurationSec * 2 + gapSeconds

        #expect(abs(fileDurationSec - expectedDurationSec) < 0.15,
                "File \(fileDurationSec)s vs expected \(expectedDurationSec)s after reconnect gap fill")
    }
}

// MARK: - Writer-thread non-blocking tests

@Suite("Mic capture writer thread")
struct MicCaptureWriterThreadTests {
    /// Writes a first buffer, then a second 60 seconds later (triggering
    /// a long gap fill), followed by 10 contiguous buffers. Verifies all
    /// buffers appear in the file and the duration accounts for the gap.
    /// End-to-end correctness check; see `tapCallsBoundedDuringGapFill`
    /// for the non-blocking timing proof.
    @Test("Long gap fill preserves all subsequent buffers")
    func longGapFillPreservesAllBuffers() throws {
        let url = MicCaptureTestHelpers.temporaryRecording()
        defer { try? FileManager.default.removeItem(at: url) }
        let session = try MicCaptureSession(url: url, encoder: .voice, onFirstBuffer: nil)
        let tap = session.makeTapHandler()

        let sampleRate = EncoderSettings.voice.processingFormat.sampleRate
        let buffer = try MicCaptureTestHelpers.toneBuffer()
        let bufferDurationSec = Double(buffer.frameLength) / sampleRate
        let gapSeconds = 60.0
        let trailingCount = 10

        // First buffer at t=1 s.
        tap(buffer, MicCaptureTestHelpers.timestamp(seconds: 1))

        // Second buffer after a 60 s gap.
        let gapTimeSec = 1.0 + bufferDurationSec + gapSeconds
        tap(buffer, MicCaptureTestHelpers.timestampNanos(UInt64(gapTimeSec * 1_000_000_000)))

        // Immediately enqueue more contiguous buffers.
        var nextNanos = UInt64((gapTimeSec + bufferDurationSec) * 1_000_000_000)
        for _ in 0 ..< trailingCount {
            tap(buffer, MicCaptureTestHelpers.timestampNanos(nextNanos))
            nextNanos += UInt64(bufferDurationSec * 1_000_000_000)
        }

        // close() drains the writer thread before disposing the file.
        session.close()

        let totalBuffers = 2 + trailingCount
        let expectedDurationSec = bufferDurationSec * Double(totalBuffers) + gapSeconds
        let audio = try AVAudioFile(forReading: url)
        let fileDurationSec = Double(audio.length) / audio.processingFormat.sampleRate

        #expect(abs(fileDurationSec - expectedDurationSec) < 0.2,
                "File \(fileDurationSec)s vs expected \(expectedDurationSec)s — buffers may have been dropped during gap fill")
    }

    /// Same as longGapFillPreservesAllBuffers but through the 48 kHz →
    /// 24 kHz converter path.
    @Test("Long gap fill through 48 kHz converter path preserves all buffers")
    func longGapFillConverterPathPreservesAllBuffers() throws {
        let url = MicCaptureTestHelpers.temporaryRecording()
        defer { try? FileManager.default.removeItem(at: url) }
        let session = try MicCaptureSession(url: url, encoder: .voice, onFirstBuffer: nil)
        let tap = session.makeTapHandler()

        let sourceRate = 48000.0
        let bufferFrames: AVAudioFrameCount = 4800 // 100 ms at 48 kHz
        let bufferDurationSec = Double(bufferFrames) / sourceRate
        let gapSeconds = 60.0
        let trailingCount = 10

        let buf1 = try MicCaptureTestHelpers.toneBuffer(sampleRate: sourceRate, frameCount: bufferFrames)
        tap(buf1, MicCaptureTestHelpers.timestampNanos(1_000_000_000))

        let gapTimeSec = 1.0 + bufferDurationSec + gapSeconds
        let buf2 = try MicCaptureTestHelpers.toneBuffer(sampleRate: sourceRate, frameCount: bufferFrames)
        tap(buf2, MicCaptureTestHelpers.timestampNanos(UInt64(gapTimeSec * 1_000_000_000)))

        var nextNanos = UInt64((gapTimeSec + bufferDurationSec) * 1_000_000_000)
        for _ in 0 ..< trailingCount {
            let buf = try MicCaptureTestHelpers.toneBuffer(sampleRate: sourceRate, frameCount: bufferFrames)
            tap(buf, MicCaptureTestHelpers.timestampNanos(nextNanos))
            nextNanos += UInt64(bufferDurationSec * 1_000_000_000)
        }

        session.close()

        let totalBuffers = 2 + trailingCount
        let expectedDurationSec = bufferDurationSec * Double(totalBuffers) + gapSeconds
        let outputRate = EncoderSettings.voice.processingFormat.sampleRate
        let audio = try AVAudioFile(forReading: url)
        let fileDurationSec = Double(audio.length) / outputRate

        #expect(abs(fileDurationSec - expectedDurationSec) < 0.2,
                "File \(fileDurationSec)s vs expected \(expectedDurationSec)s — converter path dropped buffers during gap fill")
    }

    /// Times the gap-triggering tap call itself. On the old (lock-based)
    /// design, this call performed the entire gap fill inline on the
    /// calling thread (hundreds of ms for a 1-hour gap, capped to 300 s
    /// = ~879 chunks). On the new (ring-buffer) design, it only copies
    /// into the ring and returns in microseconds. Differential: fails
    /// on old code, passes on new.
    @Test("Gap-triggering tap call returns immediately (does not fill inline)")
    func gapTriggeringTapReturnsImmediately() throws {
        let url = MicCaptureTestHelpers.temporaryRecording()
        defer { try? FileManager.default.removeItem(at: url) }
        let session = try MicCaptureSession(url: url, encoder: .voice, onFirstBuffer: nil)
        let tap = session.makeTapHandler()

        let sampleRate = EncoderSettings.voice.processingFormat.sampleRate
        let buffer = try MicCaptureTestHelpers.toneBuffer()
        let bufferDurationSec = Double(buffer.frameLength) / sampleRate
        // 1-hour gap (capped to 300 s by gapSilenceFrameCount): on
        // old code the inline fill writes ~879 silence chunks and
        // takes hundreds of ms. On new code the tap only enqueues
        // into the ring (microseconds).
        let gapSeconds = 3600.0

        // First buffer; flush so expectedNextHostNanos is set.
        tap(buffer, MicCaptureTestHelpers.timestamp(seconds: 1))
        session.flushWriter()

        // Time the gap-triggering call.
        let gapTimeSec = 1.0 + bufferDurationSec + gapSeconds
        let start = CFAbsoluteTimeGetCurrent()
        tap(buffer, MicCaptureTestHelpers.timestampNanos(UInt64(gapTimeSec * 1_000_000_000)))
        let elapsed = CFAbsoluteTimeGetCurrent() - start

        // Let the writer thread complete the fill before closing.
        session.close()

        #expect(elapsed < 0.05,
                "Gap-triggering tap took \(elapsed)s — should be <50 ms; a slow call means the gap fill ran inline")
    }

    /// Sends 96 kHz mono buffers with 9600 frames each (100 ms) through
    /// the converter path. These exceed the old 8192-frame slot limit
    /// and verify the ring slots are sized for high sample rates.
    @Test("Buffers larger than 8192 frames are accepted (96 kHz tap)")
    func largeBuffersAccepted() throws {
        let url = MicCaptureTestHelpers.temporaryRecording()
        defer { try? FileManager.default.removeItem(at: url) }
        let session = try MicCaptureSession(url: url, encoder: .voice, onFirstBuffer: nil)
        let tap = session.makeTapHandler()

        let sourceRate = 96000.0
        let bufferFrames: AVAudioFrameCount = 9600 // 100 ms at 96 kHz
        let bufferCount = 20 // 2 s of audio
        let bufferDurationSec = Double(bufferFrames) / sourceRate
        var hostNanos: UInt64 = 1_000_000_000

        for _ in 0 ..< bufferCount {
            let buf = try MicCaptureTestHelpers.toneBuffer(
                sampleRate: sourceRate, frameCount: bufferFrames
            )
            tap(buf, MicCaptureTestHelpers.timestampNanos(hostNanos))
            hostNanos += UInt64(bufferDurationSec * 1_000_000_000)
        }

        session.close()

        let totalDurationSec = bufferDurationSec * Double(bufferCount)
        let outputRate = EncoderSettings.voice.processingFormat.sampleRate
        let audio = try AVAudioFile(forReading: url)
        let fileDurationSec = Double(audio.length) / outputRate

        #expect(abs(fileDurationSec - totalDurationSec) < 0.15,
                "File \(fileDurationSec)s vs expected \(totalDurationSec)s — large buffers may have been dropped")
    }
}

// MARK: - Content fidelity (48 kHz → 24 kHz converter path)

@Suite("Mic capture content fidelity")
struct MicCaptureContentFidelityTests {
    /// A phase-continuous tone sent as a 4-channel 48 kHz tap (as the VPIO
    /// tap delivers on real hardware) must come out of the 24 kHz AAC file
    /// as the same clean tone. Duration-only tests cannot see corrupted
    /// samples; this decodes the file and checks every 100 ms window.
    @Test("Resampled mic audio is a clean copy of channel 0", arguments: [4800, 1024, 441])
    func resampledToneIsClean(bufferFrames: Int) throws {
        let url = MicCaptureTestHelpers.temporaryRecording()
        defer { try? FileManager.default.removeItem(at: url) }
        let session = try MicCaptureSession(url: url, encoder: .voice, onFirstBuffer: nil)
        defer { session.close() }
        let tap = session.makeTapHandler()

        let sourceRate = 48000.0
        let toneHz = 400.0
        let totalFrames = Int(sourceRate * 3) // 3 s
        // More than 2 channels needs an explicit layout.
        let layout = try #require(AVAudioChannelLayout(layoutTag: kAudioChannelLayoutTag_DiscreteInOrder | 4))
        let format = AVAudioFormat(standardFormatWithSampleRate: sourceRate, channelLayout: layout)
        var noise = SystemRandomNumberGenerator()
        var frameIndex = 0
        var hostNanos: UInt64 = 1_000_000_000
        while frameIndex < totalFrames {
            let count = min(bufferFrames, totalFrames - frameIndex)
            let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(count)))
            buffer.frameLength = AVAudioFrameCount(count)
            let channels = try #require(buffer.floatChannelData)
            for frame in 0 ..< count {
                let phase = 2 * Double.pi * toneHz * Double(frameIndex + frame) / sourceRate
                channels[0][frame] = Float(0.3 * sin(phase))
                for channel in 1 ..< 4 {
                    channels[channel][frame] = Float.random(in: -0.3 ... 0.3, using: &noise)
                }
            }
            tap(buffer, MicCaptureTestHelpers.timestampNanos(hostNanos))
            hostNanos += UInt64(Double(count) / sourceRate * 1_000_000_000)
            frameIndex += count
        }
        session.close()

        let samples = try MicCaptureTestHelpers.decodedSamples(url)
        let outputRate = EncoderSettings.voice.processingFormat.sampleRate
        // 100 ms windows hold a whole number of tone cycles (40), so a clean
        // tone puts ~all of its energy in the tone bin at any phase.
        let window = Int(outputRate / 10)
        // Skip AAC priming at the start and padding at the end.
        let start = window * 2
        let end = samples.count - window * 2
        try #require(end > start + window)
        var worst = 1.0
        var offset = start
        while offset + window <= end {
            let slice = samples[offset ..< offset + window]
            worst = min(worst, MicCaptureTestHelpers.toneEnergyRatio(slice, toneHz: toneHz, sampleRate: outputRate))
            offset += window
        }
        #expect(worst > 0.9, "Worst 100 ms window has only \(worst) of its energy in the \(toneHz) Hz tone — mic audio is corrupted")
    }
}

// MARK: - Shared test helpers

enum MicCaptureTestHelpers {
    static func temporaryRecording() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("mic-session-\(UUID()).aac")
    }

    /// Creates a mono PCM buffer at the processing rate (24 kHz).
    static func toneBuffer() throws -> AVAudioPCMBuffer {
        try toneBuffer(sampleRate: EncoderSettings.voice.processingFormat.sampleRate, frameCount: 8192)
    }

    /// Creates a mono PCM buffer at the given sample rate and frame count,
    /// filled with a simple tone. For rates other than the processing rate
    /// (24 kHz), this exercises the AVAudioConverter resampling path.
    static func toneBuffer(sampleRate: Double, frameCount: AVAudioFrameCount) throws -> AVAudioPCMBuffer {
        let format = try #require(AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: sampleRate,
            channels: 1,
            interleaved: false
        ))
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount))
        buffer.frameLength = frameCount
        let samples = try #require(buffer.floatChannelData?[0])
        for frame in 0 ..< Int(frameCount) {
            samples[frame] = 0.2 * sin(Float(frame) * 0.1)
        }
        return buffer
    }

    static func timestamp(seconds: UInt64) -> AVAudioTime {
        AVAudioTime(hostTime: AudioConvertNanosToHostTime(seconds * 1_000_000_000))
    }

    static func timestampNanos(_ nanos: UInt64) -> AVAudioTime {
        AVAudioTime(hostTime: AudioConvertNanosToHostTime(nanos))
    }

    /// Decodes a recording to mono float samples at the file's processing rate.
    static func decodedSamples(_ url: URL) throws -> [Float] {
        let audio = try AVAudioFile(forReading: url)
        let buffer = try #require(AVAudioPCMBuffer(
            pcmFormat: audio.processingFormat, frameCapacity: AVAudioFrameCount(audio.length)
        ))
        try audio.read(into: buffer)
        let data = try #require(buffer.floatChannelData?[0])
        return Array(UnsafeBufferPointer(start: data, count: Int(buffer.frameLength)))
    }

    /// Fraction of the slice's energy at `toneHz` (Goertzel). Near 1 for a
    /// clean tone over a whole number of cycles; low for distorted audio.
    static func toneEnergyRatio(_ slice: ArraySlice<Float>, toneHz: Double, sampleRate: Double) -> Double {
        let omega = 2 * Double.pi * toneHz / sampleRate
        var real = 0.0
        var imag = 0.0
        var total = 0.0
        for (index, sample) in slice.enumerated() {
            let value = Double(sample)
            real += value * cos(omega * Double(index))
            imag -= value * sin(omega * Double(index))
            total += value * value
        }
        guard total > 0 else { return 0 }
        return 2 * (real * real + imag * imag) / (Double(slice.count) * total)
    }
}
