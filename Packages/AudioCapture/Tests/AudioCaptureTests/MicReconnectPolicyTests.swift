import AudioToolbox
import AVFoundation
import Testing
@testable import AudioCapture

/// Device IDs from the AirPods removal logged on 2026-10-25.
private let airPods = MicRoute(inputID: 220, outputID: 214)
private let builtIn = MicRoute(inputID: 90, outputID: 83)

@Suite("MicReconnectPolicy")
struct MicReconnectPolicyTests {
    /// A stale request after an AirPods flap: the engine already runs on the
    /// current route and delivers audio.
    @Test("Keeps a running engine that delivers audio on the current route")
    func keepsEngineOnCurrentRoute() {
        let decision = MicReconnectPolicy.decide(
            builtRoute: builtIn, currentRoute: builtIn, isRunning: true, hasDeliveredAudio: true
        )
        #expect(decision == .keepEngine)
    }

    /// A rebuild has just started the engine for this route, and its tap has
    /// not delivered audio yet.
    @Test("Waits for the first buffer of a fresh engine on the current route")
    func awaitsFirstBufferOfFreshEngine() {
        let decision = MicReconnectPolicy.decide(
            builtRoute: builtIn, currentRoute: builtIn, isRunning: true, hasDeliveredAudio: false
        )
        #expect(decision == .awaitFirstBuffer)
    }

    /// The default input moved from the AirPods to the built-in mic.
    @Test("Rebuilds when the default input changed")
    func rebuildsOnInputChange() {
        let decision = MicReconnectPolicy.decide(
            builtRoute: airPods, currentRoute: MicRoute(inputID: 90, outputID: 214),
            isRunning: true, hasDeliveredAudio: true
        )
        #expect(decision == .rebuild)
    }

    /// Voice processing also uses the output, as its echo reference, so an
    /// output change alone makes the engine's route stale.
    @Test("Rebuilds when only the default output changed")
    func rebuildsOnOutputChange() {
        let decision = MicReconnectPolicy.decide(
            builtRoute: builtIn, currentRoute: MicRoute(inputID: 90, outputID: 214),
            isRunning: true, hasDeliveredAudio: true
        )
        #expect(decision == .rebuild)
    }

    /// A stopped engine delivers no audio, whatever its route.
    @Test("Rebuilds a stopped engine even on the current route")
    func rebuildsStoppedEngine() {
        let decision = MicReconnectPolicy.decide(
            builtRoute: builtIn, currentRoute: builtIn, isRunning: false, hasDeliveredAudio: true
        )
        #expect(decision == .rebuild)
    }

    /// Without both routes (after a teardown, or with no default device) the
    /// policy cannot tell that a request is stale.
    @Test("Rebuilds when the built or current route is unknown")
    func rebuildsOnUnknownRoute() {
        #expect(MicReconnectPolicy.decide(
            builtRoute: nil, currentRoute: builtIn, isRunning: true, hasDeliveredAudio: true
        ) == .rebuild)
        #expect(MicReconnectPolicy.decide(
            builtRoute: builtIn, currentRoute: nil, isRunning: true, hasDeliveredAudio: true
        ) == .rebuild)
    }
}

@Suite("Stale mic reconnect through the real writer")
struct StaleMicReconnectWriterTests {
    private typealias Tap = @Sendable (AVAudioPCMBuffer, AVAudioTime) -> Void

    private static let toneHz = 400.0
    private static let bufferFrames = 441

    /// Replays the AirPods removal logged on 2026-10-25. The default input
    /// changed three times; the first rebuild took 3.37 s and ended on the
    /// built-in mic, so the two later requests are stale. Before this policy
    /// they rebuilt the engine again and left a second gap (3.07 s on
    /// hardware) 0.5 s after the first. Now the file has a single gap.
    @Test("AirPods removal flap leaves one gap in the mic file")
    func airPodsRemovalFlapLeavesOneGap() throws {
        let url = MicCaptureTestHelpers.temporaryRecording()
        defer { try? FileManager.default.removeItem(at: url) }
        let session = try MicCaptureSession(url: url, encoder: .voice, onFirstBuffer: nil)
        defer { session.close() }

        // AirPods (hands-free) tap: 24 kHz, 3 channels. The built-in tap is
        // 48 kHz, 9 channels, through the 48 → 24 kHz converter.
        let builtInFormat = try tapFormat(sampleRate: 48000, channels: 9)
        var engineRoute = airPods
        var tap = session.makeTapHandler()
        var clock = 2.0
        try feed(tap, session: session, format: tapFormat(sampleRate: 24000, channels: 3), from: 0, to: clock)

        var decisions: [MicReconnectDecision] = []
        /// Acts on a request as the engine does. A rebuild stops the tap for
        /// the time the rebuild took on hardware.
        func reconnect(rebuildSeconds: Double) {
            let decision = decide(engineRoute, current: builtIn, session: session)
            decisions.append(decision)
            guard decision != .keepEngine else { return }
            session.invalidateTap()
            engineRoute = builtIn
            clock += rebuildSeconds
            tap = session.makeTapHandler()
        }

        // AirPods removed at 2 s; the first request rebuilds for the built-in mic.
        reconnect(rebuildSeconds: 3.37)
        try feed(tap, session: session, format: builtInFormat, from: clock, to: clock + 0.5)
        clock += 0.5
        // Two stale requests arrive after the engine delivers audio again.
        reconnect(rebuildSeconds: 3.07)
        reconnect(rebuildSeconds: 3.07)
        try feed(tap, session: session, format: builtInFormat, from: clock, to: clock + 4.13)
        session.close()

        #expect(decisions == [.rebuild, .keepEngine, .keepEngine])

        let samples = try MicCaptureTestHelpers.decodedSamples(url)
        let rate = EncoderSettings.voice.processingFormat.sampleRate
        let duration = Double(samples.count) / rate
        #expect(abs(duration - 10) < 0.2, "Mic file is \(duration)s for a 10 s timeline")

        // One silence, as long as the first rebuild. Two more rebuilds would
        // add a second silence and 6.14 s to the file.
        let gaps = silentRuns(samples, sampleRate: rate)
        try #require(gaps.count == 1, "Silent runs (start s, length s): \(gaps)")
        #expect(abs(gaps[0].start - 2) < 0.15, "The gap starts at \(gaps[0].start)s, not at the removal")
        #expect(abs(gaps[0].length - 3.37) < 0.1, "The gap is \(gaps[0].length)s, not the 3.37 s rebuild")
    }

    // MARK: - Helpers

    /// Applies the policy as `LiveMicCaptureEngine.reconnect()` does, with the
    /// session's real tap-delivery flag. Rebuild is the only other outcome.
    private func decide(_ built: MicRoute, current: MicRoute, session: MicCaptureSession) -> MicReconnectDecision {
        MicReconnectPolicy.decide(
            builtRoute: built, currentRoute: current,
            isRunning: true, hasDeliveredAudio: session.hasDeliveredBuffer
        )
    }

    /// A tap format like voice processing's: non-interleaved Float32 with a
    /// discrete channel layout.
    private func tapFormat(sampleRate: Double, channels: UInt32) throws -> AVAudioFormat {
        // More than 2 channels needs an explicit layout.
        let layout = try #require(AVAudioChannelLayout(layoutTag: kAudioChannelLayoutTag_DiscreteInOrder | channels))
        return AVAudioFormat(standardFormatWithSampleRate: sampleRate, channelLayout: layout)
    }

    /// Sends the tone on channel 0 and noise on the other channels from
    /// `start` to `end` seconds, in odd-sized buffers with contiguous host
    /// times. The tone phase follows the timeline, so it stays continuous
    /// across a change of tap format. Waits for the writer every 64 buffers:
    /// faster than real time, the session's 256-slot ring would drop buffers.
    private func feed(
        _ tap: Tap, session: MicCaptureSession, format: AVAudioFormat, from start: Double, to end: Double
    ) throws {
        let rate = format.sampleRate
        let channelCount = Int(format.channelCount)
        let first = Int((start * rate).rounded())
        let last = Int((end * rate).rounded())
        var noise = SystemRandomNumberGenerator()
        var frame = first
        var sent = 0
        while frame < last {
            if sent % 64 == 63 { session.flushWriter() }
            sent += 1
            let count = min(Self.bufferFrames, last - frame)
            let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(count)))
            buffer.frameLength = AVAudioFrameCount(count)
            let channels = try #require(buffer.floatChannelData)
            for offset in 0 ..< count {
                let seconds = Double(frame + offset) / rate
                channels[0][offset] = Float(0.3 * sin(2 * Double.pi * Self.toneHz * seconds))
                for channel in 1 ..< channelCount {
                    channels[channel][offset] = Float.random(in: -0.3 ... 0.3, using: &noise)
                }
            }
            let hostNanos = UInt64((1 + Double(frame) / rate) * 1_000_000_000)
            tap(buffer, MicCaptureTestHelpers.timestampNanos(hostNanos))
            frame += count
        }
    }

    /// Runs of silent 10 ms chunks (peak below 0.01) that last at least 0.5 s.
    /// Shorter runs are AAC priming and padding at the file edges.
    private func silentRuns(_ samples: [Float], sampleRate: Double) -> [(start: Double, length: Double)] {
        let chunk = Int(sampleRate / 100)
        var runs: [(start: Double, length: Double)] = []
        var runStart: Int?
        var offset = 0
        while offset <= samples.count {
            let end = min(offset + chunk, samples.count)
            let silent = offset < end && samples[offset ..< end].allSatisfy { abs($0) < 0.01 }
            if silent, runStart == nil { runStart = offset }
            if !silent, let start = runStart {
                let length = Double(offset - start) / sampleRate
                if length >= 0.5 { runs.append((Double(start) / sampleRate, length)) }
                runStart = nil
            }
            offset += chunk
        }
        return runs
    }
}
