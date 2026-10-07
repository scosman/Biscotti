import AudioToolbox
import AVFoundation
import Foundation
import Testing
@testable import AudioCapture

@Suite("System gap fill writer")
struct SystemGapFillTests {
    /// Writes 50 continuous buffers with contiguous host times.
    /// No gap fill should trigger and file duration should match the
    /// total input span.
    @Test("Continuous buffers at same rate produce no gap fills")
    func continuousBuffersNoGapFill() throws {
        let ctx = try TestContext(tapSampleRate: 24000)
        defer { ctx.dispose() }
        let writer = SystemGapFillWriter()

        let rate = 24000.0
        let framesPerBuffer: UInt32 = 1024
        let bufferCount = 50
        var hostNanos: UInt64 = 1_000_000_000

        for _ in 0 ..< bufferCount {
            let filled = writer.processBuffer(
                hostTimeNanos: hostNanos,
                bufferFrameCount: framesPerBuffer,
                channelCount: 1,
                sampleRate: rate,
                file: ctx.file
            )
            #expect(filled == 0, "Continuous buffers should not trigger gap fill")

            ctx.writeToneBuffer(frameCount: framesPerBuffer, channelCount: 1)

            let durationNanos = UInt64(Double(framesPerBuffer) / rate * 1_000_000_000)
            hostNanos += durationNanos
        }

        let expectedDuration = Double(framesPerBuffer) * Double(bufferCount) / rate
        let fileDuration = try ctx.fileDuration()
        // AAC adds ~2048 frames = ~0.085 s at 24 kHz padding.
        #expect(abs(fileDuration - expectedDuration) < 0.15,
                "File \(fileDuration)s vs expected \(expectedDuration)s — false gap fills inflated the file")
    }

    /// Writes two buffers with a 2-second gap. The file duration should
    /// include the gap fill.
    @Test("Real multi-second gap is filled with silence")
    func realGapFilled() throws {
        let ctx = try TestContext(tapSampleRate: 24000)
        defer { ctx.dispose() }
        let writer = SystemGapFillWriter()

        let rate = 24000.0
        let framesPerBuffer: UInt32 = 1024
        let bufferDuration = Double(framesPerBuffer) / rate
        let gapSeconds = 2.0
        let startNanos: UInt64 = 1_000_000_000

        // First buffer.
        let filled1 = writer.processBuffer(
            hostTimeNanos: startNanos,
            bufferFrameCount: framesPerBuffer,
            channelCount: 1,
            sampleRate: rate,
            file: ctx.file
        )
        #expect(filled1 == 0, "First buffer should not trigger gap fill")
        ctx.writeToneBuffer(frameCount: framesPerBuffer, channelCount: 1)

        // Second buffer after a 2-second gap.
        let secondNanos = startNanos + UInt64((bufferDuration + gapSeconds) * 1_000_000_000)
        let filled2 = writer.processBuffer(
            hostTimeNanos: secondNanos,
            bufferFrameCount: framesPerBuffer,
            channelCount: 1,
            sampleRate: rate,
            file: ctx.file
        )
        #expect(filled2 > 0, "A 2 s gap should trigger gap fill")
        let expectedFillFrames = Int((gapSeconds * rate).rounded())
        #expect(filled2 == expectedFillFrames)
        ctx.writeToneBuffer(frameCount: framesPerBuffer, channelCount: 1)

        let expectedDuration = bufferDuration * 2 + gapSeconds
        let fileDuration = try ctx.fileDuration()
        #expect(abs(fileDuration - expectedDuration) < 0.15,
                "File \(fileDuration)s vs expected \(expectedDuration)s — gap fill missing")
    }

    /// Simulates a reconnect: writes buffers, resets nothing on the
    /// writer (expectedNextHostNanos persists), then writes more buffers
    /// with a gap. The gap should be filled.
    @Test("Gap across reconnect is filled")
    func gapAcrossReconnect() throws {
        let ctx = try TestContext(tapSampleRate: 24000)
        defer { ctx.dispose() }
        let writer = SystemGapFillWriter()

        let rate = 24000.0
        let framesPerBuffer: UInt32 = 1024
        let bufferDuration = Double(framesPerBuffer) / rate
        let gapSeconds = 1.5
        let startNanos: UInt64 = 1_000_000_000

        // Pre-reconnect buffer.
        writer.processBuffer(
            hostTimeNanos: startNanos,
            bufferFrameCount: framesPerBuffer,
            channelCount: 1,
            sampleRate: rate,
            file: ctx.file
        )
        ctx.writeToneBuffer(frameCount: framesPerBuffer, channelCount: 1)

        // Reconnect: writer state persists (no reset).
        // Post-reconnect buffer arrives after a 1.5 s gap.
        let postReconnectNanos = startNanos + UInt64((bufferDuration + gapSeconds) * 1_000_000_000)
        let filled = writer.processBuffer(
            hostTimeNanos: postReconnectNanos,
            bufferFrameCount: framesPerBuffer,
            channelCount: 1,
            sampleRate: rate,
            file: ctx.file
        )
        #expect(filled > 0, "Gap across reconnect should be filled")
        ctx.writeToneBuffer(frameCount: framesPerBuffer, channelCount: 1)

        let expectedDuration = bufferDuration * 2 + gapSeconds
        let fileDuration = try ctx.fileDuration()
        #expect(abs(fileDuration - expectedDuration) < 0.15,
                "File \(fileDuration)s vs expected \(expectedDuration)s after reconnect gap fill")
    }

    /// Tap delivers at 48 kHz; file output is 24 kHz. Verifies gap fill
    /// duration is correct when ExtAudioFile resamples internally.
    @Test("Gap fill correct when tap rate differs from file rate")
    func gapFillWithRateMismatch() throws {
        let tapRate = 48000.0
        let ctx = try TestContext(tapSampleRate: tapRate)
        defer { ctx.dispose() }
        let writer = SystemGapFillWriter()

        let framesPerBuffer: UInt32 = 4800 // 100 ms at 48 kHz
        let bufferDuration = Double(framesPerBuffer) / tapRate
        let gapSeconds = 2.0
        let startNanos: UInt64 = 1_000_000_000

        // First buffer.
        writer.processBuffer(
            hostTimeNanos: startNanos,
            bufferFrameCount: framesPerBuffer,
            channelCount: 1,
            sampleRate: tapRate,
            file: ctx.file
        )
        ctx.writeToneBuffer(frameCount: framesPerBuffer, channelCount: 1)

        // Second buffer after a 2-second gap.
        let secondNanos = startNanos + UInt64((bufferDuration + gapSeconds) * 1_000_000_000)
        let filled = writer.processBuffer(
            hostTimeNanos: secondNanos,
            bufferFrameCount: framesPerBuffer,
            channelCount: 1,
            sampleRate: tapRate,
            file: ctx.file
        )
        #expect(filled > 0, "Gap should be filled despite rate mismatch")
        // Fill frames are at the tap rate (48 kHz), not the file rate.
        let expectedFillFrames = Int((gapSeconds * tapRate).rounded())
        #expect(filled == expectedFillFrames)
        ctx.writeToneBuffer(frameCount: framesPerBuffer, channelCount: 1)

        // File duration should match regardless of the internal resample.
        let expectedDuration = bufferDuration * 2 + gapSeconds
        let fileDuration = try ctx.fileDuration()
        #expect(abs(fileDuration - expectedDuration) < 0.15,
                "File \(fileDuration)s vs expected \(expectedDuration)s with rate mismatch")
    }

    /// Jitter gap (below 100 ms threshold) must not trigger silence fill.
    @Test("Jitter gap below threshold does not trigger fill")
    func jitterGapNotFilled() throws {
        let ctx = try TestContext(tapSampleRate: 24000)
        defer { ctx.dispose() }
        let writer = SystemGapFillWriter()

        let rate = 24000.0
        let framesPerBuffer: UInt32 = 1024
        let bufferDuration = Double(framesPerBuffer) / rate
        let startNanos: UInt64 = 1_000_000_000

        // First buffer.
        writer.processBuffer(
            hostTimeNanos: startNanos,
            bufferFrameCount: framesPerBuffer,
            channelCount: 1,
            sampleRate: rate,
            file: ctx.file
        )
        ctx.writeToneBuffer(frameCount: framesPerBuffer, channelCount: 1)

        // Second buffer 1 ms late (jitter, below 100 ms threshold).
        let secondNanos = startNanos + UInt64((bufferDuration + 0.001) * 1_000_000_000)
        let filled = writer.processBuffer(
            hostTimeNanos: secondNanos,
            bufferFrameCount: framesPerBuffer,
            channelCount: 1,
            sampleRate: rate,
            file: ctx.file
        )
        #expect(filled == 0, "1 ms jitter should not trigger gap fill")
        ctx.writeToneBuffer(frameCount: framesPerBuffer, channelCount: 1)

        // File should contain only two buffers worth of audio.
        let expectedDuration = bufferDuration * 2
        let fileDuration = try ctx.fileDuration()
        #expect(fileDuration < expectedDuration + 0.5,
                "File \(fileDuration)s should not contain gap silence")
    }
}

// MARK: - Test context

/// Manages a temporary ExtAudioFile for testing `SystemGapFillWriter`.
///
/// Creates an ADTS AAC file at 24 kHz output with a client format at
/// the specified tap sample rate, mirroring how `LiveSystemCaptureEngine`
/// sets up its file.
private final class TestContext {
    let url: URL
    let file: ExtAudioFileRef
    private let tapSampleRate: Double
    private var disposed = false

    init(tapSampleRate: Double) throws {
        self.tapSampleRate = tapSampleRate
        url = FileManager.default.temporaryDirectory
            .appendingPathComponent("system-gap-fill-\(UUID()).aac")

        // Create ADTS AAC output file at 24 kHz.
        let encoder = EncoderSettings.voice
        var outputASBD = encoder.outputASBD()
        var fileRef: ExtAudioFileRef?
        let createStatus = ExtAudioFileCreateWithURL(
            url as CFURL,
            encoder.fileType,
            &outputASBD,
            nil,
            AudioFileFlags.eraseFile.rawValue,
            &fileRef
        )
        guard createStatus == noErr, let ref = fileRef else {
            throw TestError("ExtAudioFileCreateWithURL failed: \(createStatus)")
        }
        file = ref

        // Set client format: interleaved float PCM at the tap's rate.
        let bytesPerFrame = UInt32(MemoryLayout<Float>.size)
        var clientASBD = AudioStreamBasicDescription(
            mSampleRate: tapSampleRate,
            mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked,
            mBytesPerPacket: bytesPerFrame,
            mFramesPerPacket: 1,
            mBytesPerFrame: bytesPerFrame,
            mChannelsPerFrame: 1,
            mBitsPerChannel: 32,
            mReserved: 0
        )
        let clientStatus = ExtAudioFileSetProperty(
            file,
            kExtAudioFileProperty_ClientDataFormat,
            UInt32(MemoryLayout<AudioStreamBasicDescription>.size),
            &clientASBD
        )
        guard clientStatus == noErr else {
            ExtAudioFileDispose(file)
            throw TestError("Client format set failed: \(clientStatus)")
        }
    }

    /// Writes a non-zero tone buffer at the tap's sample rate.
    func writeToneBuffer(frameCount: UInt32, channelCount: UInt32) {
        let sampleCount = Int(frameCount * channelCount)
        var samples = [Float](repeating: 0, count: sampleCount)
        for idx in 0 ..< sampleCount {
            samples[idx] = 0.2 * sin(Float(idx) * 0.1)
        }
        samples.withUnsafeMutableBytes { raw in
            guard let base = raw.baseAddress else { return }
            let buffer = AudioBuffer(
                mNumberChannels: channelCount,
                mDataByteSize: UInt32(sampleCount * MemoryLayout<Float>.size),
                mData: base
            )
            var bufferList = AudioBufferList(mNumberBuffers: 1, mBuffers: buffer)
            let status = ExtAudioFileWrite(file, frameCount, &bufferList)
            precondition(status == noErr, "Test tone write failed: \(status)")
        }
    }

    /// Closes the file and reads back the decoded duration in seconds.
    func fileDuration() throws -> Double {
        if !disposed {
            ExtAudioFileDispose(file)
            disposed = true
        }
        let audio = try AVAudioFile(forReading: url)
        return Double(audio.length) / audio.processingFormat.sampleRate
    }

    func dispose() {
        if !disposed {
            ExtAudioFileDispose(file)
            disposed = true
        }
        try? FileManager.default.removeItem(at: url)
    }

    deinit {
        dispose()
    }
}

private struct TestError: Error, CustomStringConvertible {
    let description: String
    init(_ message: String) {
        description = message
    }
}
