import AVFoundation
import Foundation
import QuartzCore
import Testing
@testable import AudioCapture

/// The recording-safety gate: with a live tap attached, both tracks' AAC
/// files decode to exactly the samples they hold without one.
@Suite("Live branch recording safety")
struct LiveBranchSafetyTests {
    enum TapMode: String, CaseIterable, CustomTestStringConvertible {
        /// The pump's case: another thread drains while the writer writes.
        case drainedWhileWriting
        /// Nothing drains, so the queue overflows almost at once.
        case neverDrained

        var testDescription: String {
            rawValue
        }

        func makeQueue() -> LiveAudioQueue {
            switch self {
            // Room for the whole script, so a slow drainer thread cannot
            // turn the gaps checked below into overflow.
            case .drainedWhileWriting: LiveAudioQueue(slotCount: 1024)
            case .neverDrained: LiveAudioQueue(slotCount: 2)
            }
        }
    }

    @Test("A live tap never changes the mic file", arguments: TapMode.allCases)
    func liveTapNeverChangesTheMicFile(mode: TapMode) throws {
        let plain = try recordMic(into: nil)
        #expect(plain.count > 3 * 24000)

        let queue = mode.makeQueue()
        let drainer = mode == .drainedWhileWriting ? BackgroundDrainer(queue) : nil
        let tapped = try recordMic(into: queue)

        #expect(tapped == plain)
        if let drainer {
            let blocks = drainer.finish()
            blocks.expectContinuous()
            let captureGaps = blocks.filter { $0.gapKind == .captureGap }
            #expect(captureGaps.map(\.duration) == [0.7])
        }
    }

    @Test("A live tap never changes the system file", arguments: TapMode.allCases)
    func liveTapNeverChangesTheSystemFile(mode: TapMode) throws {
        let plain = try recordSystem(into: nil)
        #expect(plain.count > 5 * 24000)

        let queue = mode.makeQueue()
        let drainer = mode == .drainedWhileWriting ? BackgroundDrainer(queue) : nil
        let tapped = try recordSystem(into: queue)

        #expect(tapped == plain)
        if let drainer {
            let blocks = drainer.finish()
            blocks.expectContinuous()
            #expect(blocks.first == DrainedBlock(startTime: 0, kind: .gap(duration: 1.5, kind: .notStarted)))
            let captureGaps = blocks.filter { $0.gapKind == .captureGap }
            #expect(captureGaps.map(\.duration) == [1])
        }
    }

    /// 4-channel 48 kHz buffers of 441 frames through the 48 → 24 kHz
    /// converter, with a 700 ms capture gap. Returns the decoded file.
    private func recordMic(into queue: LiveAudioQueue?) throws -> [Float] {
        let url = MicCaptureTestHelpers.temporaryRecording()
        defer { try? FileManager.default.removeItem(at: url) }
        let session = try MicCaptureSession(url: url, encoder: .voice, onFirstBuffer: nil, liveQueue: queue)
        let tap = session.makeTapHandler()
        var feed = try MicToneFeed(sampleRate: 48000, channelCount: 4, bufferFrames: 441)
        try feed.play(seconds: 1.5, into: session, tap: tap)
        feed.pause(seconds: 0.7)
        try feed.play(seconds: 1.5, into: session, tap: tap)
        session.close()
        if let queue { queue.close(at: queue.writtenEnd) }
        return try MicCaptureTestHelpers.decodedSamples(url)
    }

    /// 48 kHz tap buffers written to the 24 kHz file, starting 1.5 s after
    /// the mic, with a 1 s capture gap. Returns the decoded file.
    private func recordSystem(into queue: LiveAudioQueue?) throws -> [Float] {
        let file = try SystemTestFile(clientRate: 48000)
        defer { file.dispose() }
        let step = SystemWriteStep()
        step.begin(micAnchorSeconds: 100, systemStartWall: CACurrentMediaTime() - 10, liveQueue: queue)
        var feed = SystemToneFeed(sampleRate: 48000, startSeconds: 101.5)
        feed.play(seconds: 1.5, into: step, file: file.file)
        feed.pause(seconds: 1)
        feed.play(seconds: 1.5, into: step, file: file.file)
        if let queue { queue.close(at: queue.writtenEnd) }
        #expect(step.writeError == nil)
        return try file.decodedSamples()
    }
}
