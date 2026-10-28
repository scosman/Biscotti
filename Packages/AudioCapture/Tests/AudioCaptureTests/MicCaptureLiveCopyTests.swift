import AudioToolbox
import AVFoundation
import Foundation
import Testing
@testable import AudioCapture

/// The mic writer's live copy, checked against real AAC files.
@Suite("Mic capture live copy")
struct MicCaptureLiveCopyTests {
    private static let fileRate = EncoderSettings.voice.processingFormat.sampleRate

    @Test("The live copy carries exactly the samples written to the file")
    func liveCopyCarriesTheSamplesWrittenToFile() throws {
        let queue = LiveAudioQueue(slotCount: 64)
        var feed = try MicToneFeed(sampleRate: Self.fileRate, channelCount: 1, bufferFrames: 2400)
        let url = try record(into: queue) { session, tap in
            try feed.play(seconds: 2, into: session, tap: tap)
        }
        defer { try? FileManager.default.removeItem(at: url) }

        let blocks = queue.drainAll()
        #expect(blocks.last?.kind == .end)
        blocks.expectContinuous()
        #expect(blocks.sampleBlocks.allSatisfy { $0.sampleRate == Self.fileRate && $0.channelCount == 1 })
        #expect(blocks.allSamples == feed.playedChannel0)

        let decoded = try MicCaptureTestHelpers.decodedSamples(url)
        #expect(worstToneWindow(ArraySlice(decoded), skipWindows: 2) > 0.9)
    }

    @Test("Live blocks from 48 kHz input are 24 kHz mono at frame-exact times")
    func liveCopyFrom48kInputIs24kWithFrameExactTimes() throws {
        let queue = LiveAudioQueue(slotCount: 64)
        var feed = try MicToneFeed(sampleRate: 48000, channelCount: 1, bufferFrames: 4800)
        let url = try record(into: queue) { session, tap in
            try feed.play(seconds: 3, into: session, tap: tap)
        }
        defer { try? FileManager.default.removeItem(at: url) }

        let samples = queue.drainAll().sampleBlocks
        var writtenFrames = 0
        for block in samples {
            #expect(block.sampleRate == 24000 && block.channelCount == 1)
            #expect(block.startTime == Double(writtenFrames) / 24000)
            writtenFrames += block.frameCount
        }
        // The resampler still holds its latency (about 15 ms) at the end of input.
        #expect(abs(writtenFrames - 72000) < 480)
        let fileFrames = try AVAudioFile(forReading: url).length
        #expect(abs(Double(fileFrames - AVAudioFramePosition(writtenFrames))) / 24000 < 0.15)
    }

    @Test("A filled capture gap is reported at its place in the file")
    func liveCopyReportsGapFillAtTheRightTime() throws {
        let queue = LiveAudioQueue(slotCount: 64)
        var feed = try MicToneFeed(sampleRate: 48000, channelCount: 1, bufferFrames: 4800)
        let url = try record(into: queue) { session, tap in
            try feed.play(seconds: 1, into: session, tap: tap)
            feed.pause(seconds: 0.5)
            try feed.play(seconds: 1, into: session, tap: tap)
        }
        defer { try? FileManager.default.removeItem(at: url) }

        let blocks = queue.drainAll()
        blocks.expectContinuous()
        let gaps = blocks.gaps
        try #require(gaps.count == 1)
        let gap = try #require(gaps.first)
        #expect(gap.kind == .gap(duration: 0.5, kind: .captureGap))
        let gapIndex = try #require(blocks.firstIndex(of: gap))
        let framesBefore = blocks[..<gapIndex].reduce(0) { $0 + $1.frameCount }
        #expect(gap.startTime == Double(framesBefore) / 24000)
        // Within the resampler's latency of where the host clock put it.
        #expect(abs(gap.startTime - 1) < 0.02)
    }

    @Test("Odd 4-channel buffers keep the live timeline continuous and the tone clean")
    func oddBufferSizesKeepTimelineContinuous() throws {
        let queue = LiveAudioQueue(slotCount: 512)
        var feed = try MicToneFeed(sampleRate: 48000, channelCount: 4, bufferFrames: 441)
        let url = try record(into: queue) { session, tap in
            try feed.play(seconds: 3, into: session, tap: tap)
        }
        defer { try? FileManager.default.removeItem(at: url) }

        let blocks = queue.drainAll()
        #expect(blocks.gaps.isEmpty)
        blocks.expectContinuous()
        #expect(abs(blocks.allSamples.count - 72000) < 480)
        #expect(worstToneWindow(ArraySlice(blocks.allSamples), skipWindows: 1) > 0.99)
    }

    @Test("A full live queue never changes the file")
    func fullLiveQueueNeverChangesTheFile() throws {
        func script(
            _ feed: inout MicToneFeed,
            _ session: MicCaptureSession,
            _ tap: (AVAudioPCMBuffer, AVAudioTime) -> Void
        ) throws {
            try feed.play(seconds: 1.5, into: session, tap: tap)
            feed.pause(seconds: 0.7)
            try feed.play(seconds: 1.5, into: session, tap: tap)
        }
        var plainFeed = try MicToneFeed(sampleRate: 48000, channelCount: 4, bufferFrames: 441)
        let plainURL = try record(into: nil) { try script(&plainFeed, $0, $1) }
        defer { try? FileManager.default.removeItem(at: plainURL) }

        let tinyQueue = LiveAudioQueue(slotCount: 2)
        var tappedFeed = try MicToneFeed(sampleRate: 48000, channelCount: 4, bufferFrames: 441)
        let tappedURL = try record(into: tinyQueue) { try script(&tappedFeed, $0, $1) }
        defer { try? FileManager.default.removeItem(at: tappedURL) }

        #expect(try MicCaptureTestHelpers.decodedSamples(tappedURL) == MicCaptureTestHelpers.decodedSamples(plainURL))

        let blocks = tinyQueue.drainAll()
        #expect(blocks.map(\.gapKind) == [nil, nil, .overflow, nil])
        #expect(blocks.last?.kind == .end)
        blocks.expectContinuous()
        #expect(tinyQueue.droppedDuration > 3)
    }

    @Test("A buffer the file refuses is not copied, and the live timeline stays the file's")
    func failedWriteSendsNoLiveCopy() throws {
        let queue = LiveAudioQueue(slotCount: 64)
        let url = MicCaptureTestHelpers.temporaryRecording()
        defer { try? FileManager.default.removeItem(at: url) }
        let session = try MicCaptureSession(
            url: url, encoder: .voice, onFirstBuffer: nil, liveQueue: queue, makeFile: Self.fileRefusingWrites
        )
        var feed = try MicToneFeed(sampleRate: Self.fileRate, channelCount: 1, bufferFrames: 2400)
        try feed.play(seconds: 0.5, into: session, tap: session.makeTapHandler())
        session.close()
        queue.close(at: queue.writtenEnd)

        #expect(session.writeError != nil)
        #expect(queue.drainAll() == [DrainedBlock(startTime: 0, kind: .end)])
    }

    // MARK: - Helpers

    /// An AAC file whose client format stays compressed, so every PCM write fails.
    private static func fileRefusingWrites(url: URL, encoder: EncoderSettings, _: AVAudioFormat) throws -> ExtAudioFileRef {
        var outputASBD = encoder.outputASBD()
        var fileRef: ExtAudioFileRef?
        let status = ExtAudioFileCreateWithURL(
            url as CFURL, encoder.fileType, &outputASBD, nil, AudioFileFlags.eraseFile.rawValue, &fileRef
        )
        guard status == noErr, let fileRef else {
            throw CaptureError.micEngineFailed("Test file creation failed (OSStatus \(status))")
        }
        return fileRef
    }

    /// Runs `script` against a new session writing a temporary file, closes the
    /// session and then the queue, as `AudioRecorder.stop()` does, and
    /// returns the file.
    private func record(
        into queue: LiveAudioQueue?,
        _ script: (MicCaptureSession, @escaping @Sendable (AVAudioPCMBuffer, AVAudioTime) -> Void) throws -> Void
    ) throws -> URL {
        let url = MicCaptureTestHelpers.temporaryRecording()
        let session = try MicCaptureSession(url: url, encoder: .voice, onFirstBuffer: nil, liveQueue: queue)
        let tap = session.makeTapHandler()
        try script(session, tap)
        session.close()
        if let queue { queue.close(at: queue.writtenEnd) }
        return url
    }

    /// The lowest share of energy in the 400 Hz tone over 100 ms windows,
    /// after skipping the first `skipWindows` (encoder or resampler start-up)
    /// and the last two (encoder padding).
    private func worstToneWindow(_ samples: ArraySlice<Float>, skipWindows: Int) -> Double {
        let window = Int(Self.fileRate / 10)
        var worst = 1.0
        var offset = samples.startIndex + window * skipWindows
        while offset + window <= samples.endIndex - window * 2 {
            let ratio = MicCaptureTestHelpers.toneEnergyRatio(
                samples[offset ..< offset + window], toneHz: 400, sampleRate: Self.fileRate
            )
            worst = min(worst, ratio)
            offset += window
        }
        return worst
    }
}
