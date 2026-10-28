import AudioToolbox
import AVFoundation
import Foundation
import Testing
@testable import AudioCapture

/// A reconnect can bring a tap in a different format (AirPods in a call drop
/// from 48 kHz to 24 kHz). The system track must keep recording through it:
/// before the fix, ExtAudioFile refused the new client format with `-66565`
/// and `system.aac` ended at the reconnect while the mic went on.
///
/// These tests drive `LiveSystemCaptureEngine.processEntry` — the code the
/// writer thread runs — with synthetic tap buffers, write a real ADTS AAC
/// file through the 24 kHz encoder, then decode it.
@Suite("System track format changes")
struct SystemFormatChangeTests {
    struct FormatChange: CustomTestStringConvertible {
        let before: TapFormat
        let after: TapFormat
        /// Test-case label, such as "48000 Hz 1 ch → 24000 Hz 1 ch".
        var testDescription: String {
            "\(before) → \(after)"
        }
    }

    struct TapFormat: CustomStringConvertible {
        let sampleRate: Double
        let channels: UInt32
        /// Short label, such as "48000 Hz 1 ch".
        var description: String {
            "\(Int(sampleRate)) Hz \(channels) ch"
        }
    }

    static let formatChanges = [
        FormatChange(before: TapFormat(sampleRate: 48000, channels: 1), after: TapFormat(sampleRate: 44100, channels: 1)),
        // AirPods switching to call mode.
        FormatChange(before: TapFormat(sampleRate: 48000, channels: 1), after: TapFormat(sampleRate: 24000, channels: 1)),
        FormatChange(before: TapFormat(sampleRate: 48000, channels: 1), after: TapFormat(sampleRate: 48000, channels: 2))
    ]

    /// Two seconds in one tap format, a reconnect to another format, then
    /// two more seconds. The decoded file must hold all four seconds, with
    /// the tone on both sides of the change and no write error.
    @Test("A tap format change mid-recording keeps the system track continuous", arguments: formatChanges)
    func formatChangeKeepsTrackContinuous(change: FormatChange) throws {
        let harness = try SystemTrackHarness(change.before)
        defer { harness.dispose() }

        try harness.deliver(seconds: 2)
        harness.reconnect(to: change.after)
        try harness.deliver(seconds: 2)
        let samples = try harness.finish()

        #expect(harness.engine.writeError == nil,
                "Write error \(String(describing: harness.engine.writeError)) after \(change.testDescription)")
        let decoded = Double(samples.count) / SystemTrackHarness.fileRate
        #expect(abs(decoded - harness.timelineSeconds) < 0.15,
                "Decoded \(decoded)s vs \(harness.timelineSeconds)s delivered — the track stopped or stretched at the change")
        // Every window on both sides of the change holds the clean tone.
        harness.expectTone(in: samples, from: 0.3, to: 1.7, label: "before the change")
        harness.expectTone(in: samples, from: 2.4, to: 3.7, label: "after the change")
    }

    /// Call mode on and off, then a 44.1 kHz stereo device. The converter
    /// is built, dropped for the unconverted path and built again; every
    /// segment must reach the file.
    @Test("Formats that change back and forth keep the track continuous")
    func repeatedFormatChanges() throws {
        let harness = try SystemTrackHarness(TapFormat(sampleRate: 48000, channels: 1))
        defer { harness.dispose() }

        try harness.deliver(seconds: 1.5)
        harness.reconnect(to: TapFormat(sampleRate: 24000, channels: 1))
        try harness.deliver(seconds: 1.5)
        harness.reconnect(to: TapFormat(sampleRate: 48000, channels: 1))
        try harness.deliver(seconds: 1.5)
        harness.reconnect(to: TapFormat(sampleRate: 44100, channels: 2))
        try harness.deliver(seconds: 1.5)
        let samples = try harness.finish()

        #expect(harness.engine.writeError == nil)
        let decoded = Double(samples.count) / SystemTrackHarness.fileRate
        #expect(abs(decoded - harness.timelineSeconds) < 0.15,
                "Decoded \(decoded)s vs \(harness.timelineSeconds)s delivered")
        harness.expectTone(in: samples, from: 0.3, to: 1.2, label: "48 kHz")
        harness.expectTone(in: samples, from: 1.9, to: 2.7, label: "24 kHz")
        harness.expectTone(in: samples, from: 3.4, to: 4.2, label: "48 kHz again")
        harness.expectTone(in: samples, from: 4.9, to: 5.7, label: "44.1 kHz stereo")
    }

    /// A reconnect that changes the format and takes 1.5 s. The gap is
    /// filled with client-rate silence, so the track keeps its length and
    /// the audio after the gap stays in place.
    @Test("A gap across a format-changing reconnect is filled at the file's rate")
    func gapAcrossFormatChangeIsFilled() throws {
        let harness = try SystemTrackHarness(TapFormat(sampleRate: 48000, channels: 1))
        defer { harness.dispose() }

        try harness.deliver(seconds: 2)
        harness.reconnect(to: TapFormat(sampleRate: 24000, channels: 1), gapSeconds: 1.5)
        try harness.deliver(seconds: 2)
        let samples = try harness.finish()

        #expect(harness.engine.writeError == nil)
        let decoded = Double(samples.count) / SystemTrackHarness.fileRate
        #expect(abs(decoded - 5.5) < 0.15, "Decoded \(decoded)s vs 5.5s (2 s + 1.5 s gap + 2 s)")
        let gap = harness.window(samples, from: 2.5, to: 3.2)
        #expect(gap.allSatisfy { abs($0) < 0.01 }, "The reconnect gap should be silence")
        harness.expectTone(in: samples, from: 3.9, to: 5.2, label: "after the gap")
    }

    /// The first tap runs at 24 kHz, as with AirPods already in call mode.
    /// Leading silence is counted at the 48 kHz client rate, so the first
    /// system frame still lands 0.5 s in, aligned with the mic.
    @Test("Leading silence is written at the file's rate when the first tap is not 48 kHz")
    func leadingSilenceAtClientRate() throws {
        let harness = try SystemTrackHarness(TapFormat(sampleRate: 24000, channels: 1))
        defer { harness.dispose() }
        // The mic's first sample came 0.5 s before the system tap's first frame.
        harness.engine.setMicAnchor(harness.nextHostSeconds - 0.5)

        try harness.deliver(seconds: 2)
        let samples = try harness.finish()

        #expect(harness.engine.writeError == nil)
        let decoded = Double(samples.count) / SystemTrackHarness.fileRate
        #expect(abs(decoded - 2.5) < 0.15, "Decoded \(decoded)s vs 2.5s (0.5 s leading silence + 2 s)")
        harness.expectTone(in: samples, from: 0.9, to: 2.2, label: "after the leading silence")
    }
}

// MARK: - Harness

/// Feeds `LiveSystemCaptureEngine` the buffers its IOProc would enqueue: a
/// phase-continuous 400 Hz tone on channel 0 (noise on any other channel),
/// interleaved Float32, with contiguous host times. A reconnect applies the
/// new tap format exactly as `reconnect()` does after recreating the tap.
private final class SystemTrackHarness {
    typealias TapFormat = SystemFormatChangeTests.TapFormat

    static let fileRate = EncoderSettings.voice.sampleRate
    static let toneHz = 400.0

    let url: URL
    let engine = LiveSystemCaptureEngine()
    /// Seconds the decoded file should hold: delivered audio plus gaps.
    private(set) var timelineSeconds = 0.0
    private var format: TapFormat
    private var hostNanos: UInt64 = 1_000_000_000
    private var tonePhase = 0.0
    private var noise = SystemRandomNumberGenerator()
    private var finished = false

    /// Host-clock seconds of the next buffer `deliver` sends.
    var nextHostSeconds: Double {
        Double(hostNanos) / 1_000_000_000
    }

    /// Opens a real system file through the engine, as `start()` does for
    /// a tap in `format`.
    init(_ format: TapFormat) throws {
        self.format = format
        url = FileManager.default.temporaryDirectory
            .appendingPathComponent("system-format-change-\(UUID()).aac")
        try engine.openAudioFile(url: url, tapSampleRate: format.sampleRate)
    }

    /// Delivers `seconds` of audio in the current tap format. Odd buffer
    /// sizes make the resampler keep part of each buffer for its next call.
    func deliver(seconds: Double, bufferFrames: Int = 441) throws {
        let totalFrames = Int(seconds * format.sampleRate)
        let channels = Int(format.channels)
        var sent = 0
        while sent < totalFrames {
            let count = min(bufferFrames, totalFrames - sent)
            var samples = [Float](repeating: 0, count: count * channels)
            for frame in 0 ..< count {
                samples[frame * channels] = Float(0.3 * sin(tonePhase))
                tonePhase += 2 * Double.pi * Self.toneHz / format.sampleRate
                for channel in 1 ..< max(channels, 1) {
                    samples[frame * channels + channel] = Float.random(in: -0.3 ... 0.3, using: &noise)
                }
            }
            samples.withUnsafeMutableBytes { raw in
                guard let base = raw.baseAddress else { return }
                engine.processEntry(AudioRingBuffer.Entry(
                    data: base,
                    dataByteSize: UInt32(raw.count),
                    frameCount: UInt32(count),
                    channelCount: format.channels,
                    hostTime: AudioConvertNanosToHostTime(hostNanos)
                ))
            }
            hostNanos += UInt64(Double(count) / format.sampleRate * 1_000_000_000)
            sent += count
        }
        timelineSeconds += Double(totalFrames) / format.sampleRate
    }

    /// Simulates a reconnect whose new tap delivers `newFormat`, starting
    /// `gapSeconds` after the last buffer.
    func reconnect(to newFormat: TapFormat, gapSeconds: Double = 0) {
        var asbd = AudioStreamBasicDescription()
        asbd.mSampleRate = newFormat.sampleRate
        asbd.mFormatID = kAudioFormatLinearPCM
        asbd.mChannelsPerFrame = newFormat.channels
        engine.applyTapFormat(asbd)
        format = newFormat
        hostNanos += UInt64(gapSeconds * 1_000_000_000)
        timelineSeconds += gapSeconds
    }

    /// Closes the file the way `stop()` does and decodes it.
    func finish() throws -> [Float] {
        engine.teardown()
        finished = true
        return try MicCaptureTestHelpers.decodedSamples(url)
    }

    /// The decoded samples from `start` to `end` seconds, clamped to the file.
    func window(_ samples: [Float], from start: Double, to end: Double) -> ArraySlice<Float> {
        let lower = min(Int(start * Self.fileRate), samples.count)
        let upper = min(Int(end * Self.fileRate), samples.count)
        return samples[lower ..< upper]
    }

    /// Expects the clean tone in every 100 ms window of `start ..< end`
    /// seconds. Silence scores 0, so a track that stopped fails here too.
    func expectTone(in samples: [Float], from start: Double, to end: Double, label: String) {
        let windowFrames = Int(Self.fileRate / 10) // 40 whole tone cycles
        let region = window(samples, from: start, to: end)
        #expect(region.count >= windowFrames, "No audio \(label): the decoded file is \(samples.count) frames")
        var worst = 1.0
        var offset = region.startIndex
        while offset + windowFrames <= region.endIndex {
            let slice = samples[offset ..< offset + windowFrames]
            worst = min(worst, MicCaptureTestHelpers.toneEnergyRatio(slice, toneHz: Self.toneHz, sampleRate: Self.fileRate))
            offset += windowFrames
        }
        #expect(worst > 0.9, "Worst 100 ms window \(label) has only \(worst) of its energy in the tone")
    }

    /// Closes the file if `finish()` has not, and deletes it.
    func dispose() {
        if !finished { engine.teardown() }
        try? FileManager.default.removeItem(at: url)
    }
}
