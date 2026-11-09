import AVFoundation
import Foundation
import Testing
@testable import AudioImport

@Suite("AVFoundationAudioConverter")
struct AVFoundationAudioConverterTests {
    private let converter = AVFoundationAudioConverter()

    // MARK: - Helpers

    /// Writes a minimal WAV file with the given parameters and returns its URL.
    private static func writeWAV( // swiftlint:disable:this function_body_length
        name: String,
        sampleRate: Double,
        channels: Int,
        durationSeconds: Double
    ) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(name)-\(UUID()).wav")

        let channelCount = AVAudioChannelCount(channels)

        // For > 2 channels, use a channel layout to avoid nil AVAudioFormat.
        let format: AVAudioFormat
        if channels > 2 {
            // Use a 5.1 layout for 6 channels, or default layout otherwise.
            var layout = AudioChannelLayout()
            layout.mChannelLayoutTag = channels == 6
                ? kAudioChannelLayoutTag_AudioUnit_5_1
                : kAudioChannelLayoutTag_DiscreteInOrder
                | UInt32(channels)
            let avLayout = AVAudioChannelLayout(layout: &layout)
            format = AVAudioFormat(
                commonFormat: .pcmFormatFloat32,
                sampleRate: sampleRate,
                interleaved: false,
                channelLayout: avLayout
            )
        } else {
            guard let fmt = AVAudioFormat(
                commonFormat: .pcmFormatFloat32,
                sampleRate: sampleRate,
                channels: channelCount,
                interleaved: false
            ) else {
                throw ImportFailure.unreadable
            }
            format = fmt
        }

        let frameCount = AVAudioFrameCount(sampleRate * durationSeconds)
        guard let buffer = AVAudioPCMBuffer(
            pcmFormat: format, frameCapacity: frameCount
        ) else {
            throw ImportFailure.unreadable
        }
        buffer.frameLength = frameCount

        // Fill with a 440 Hz sine wave on channel 0.
        guard let channelData = buffer.floatChannelData else {
            throw ImportFailure.unreadable
        }
        let samples = channelData[0]
        for idx in 0 ..< Int(frameCount) {
            samples[idx] = sin(
                Float(idx) * 2.0 * .pi * 440.0 / Float(sampleRate)
            )
        }

        // Fill remaining channels with silence.
        for channel in 1 ..< channels {
            let chSamples = channelData[channel]
            for idx in 0 ..< Int(frameCount) {
                chSamples[idx] = 0
            }
        }

        let file = try AVAudioFile(
            forWriting: url, settings: format.settings
        )
        try file.write(from: buffer)

        return url
    }

    // MARK: - Conversion tests

    @Test("stereo 44.1 kHz WAV -> mono 24 kHz ADTS")
    func stereo44kToMono24k() async throws {
        let source = try Self.writeWAV(
            name: "stereo44k", sampleRate: 44100, channels: 2,
            durationSeconds: 0.5
        )
        defer { try? FileManager.default.removeItem(at: source) }

        let dest = FileManager.default.temporaryDirectory
            .appendingPathComponent("out-\(UUID()).aac")
        defer { try? FileManager.default.removeItem(at: dest) }

        let result = try await converter.convert(
            source: source, destination: dest
        )

        #expect(result.duration > 0.4)
        #expect(result.duration < 0.6)
        #expect(result.byteSize > 0)
        #expect(FileManager.default.fileExists(atPath: dest.path))
    }

    @Test("mono 48 kHz WAV -> resampled to 24 kHz")
    func mono48kResampling() async throws {
        let source = try Self.writeWAV(
            name: "mono48k", sampleRate: 48000, channels: 1,
            durationSeconds: 0.5
        )
        defer { try? FileManager.default.removeItem(at: source) }

        let dest = FileManager.default.temporaryDirectory
            .appendingPathComponent("out-\(UUID()).aac")
        defer { try? FileManager.default.removeItem(at: dest) }

        let result = try await converter.convert(
            source: source, destination: dest
        )

        #expect(result.duration > 0.4)
        #expect(result.byteSize > 0)
    }

    @Test("6-channel downmix to mono")
    func sixChannelDownmix() async throws {
        let source = try Self.writeWAV(
            name: "sixch", sampleRate: 44100, channels: 6,
            durationSeconds: 0.5
        )
        defer { try? FileManager.default.removeItem(at: source) }

        let dest = FileManager.default.temporaryDirectory
            .appendingPathComponent("out-\(UUID()).aac")
        defer { try? FileManager.default.removeItem(at: dest) }

        let result = try await converter.convert(
            source: source, destination: dest
        )

        #expect(result.duration > 0.3)
        #expect(result.byteSize > 0)
    }

    @Test("zero-frame WAV throws and removes destination")
    func zeroFrameWav() async throws {
        // Write a WAV with valid header but zero audio frames.
        let source = FileManager.default.temporaryDirectory
            .appendingPathComponent("zeroframe-\(UUID()).wav")
        guard let format = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: 44100, channels: 1, interleaved: false
        ) else {
            Issue.record("could not create AVAudioFormat")
            return
        }
        let file = try AVAudioFile(
            forWriting: source, settings: format.settings
        )
        // Write zero frames: just close the file header with no samples.
        _ = file // keep reference alive then drop
        defer { try? FileManager.default.removeItem(at: source) }

        let dest = FileManager.default.temporaryDirectory
            .appendingPathComponent("out-\(UUID()).aac")

        do {
            _ = try await converter.convert(
                source: source, destination: dest
            )
            Issue.record("expected an ImportFailure")
        } catch let error as ImportFailure {
            // noAudio or unreadable are both acceptable -- AVFoundation may
            // reject the empty track at different stages.
            #expect(error == .noAudio || error == .unreadable)
        }

        // Destination must not exist (cleaned up by the converter).
        #expect(!FileManager.default.fileExists(atPath: dest.path))
    }

    @Test("AAC source re-encodes successfully")
    func aacSourceReencodes() async throws {
        // Create a WAV source, convert it to ADTS AAC through our converter,
        // then feed the AAC output back in as a source. This tests that the
        // converter handles compressed input.
        let wavSource = try Self.writeWAV(
            name: "aac-seed", sampleRate: 44100, channels: 1,
            durationSeconds: 0.5
        )
        defer { try? FileManager.default.removeItem(at: wavSource) }

        let aacIntermediate = FileManager.default.temporaryDirectory
            .appendingPathComponent("intermediate-\(UUID()).aac")
        defer { try? FileManager.default.removeItem(at: aacIntermediate) }

        // First pass: WAV -> AAC.
        _ = try await converter.convert(
            source: wavSource, destination: aacIntermediate
        )
        #expect(FileManager.default.fileExists(atPath: aacIntermediate.path))

        // Second pass: re-encode AAC -> AAC.
        let dest = FileManager.default.temporaryDirectory
            .appendingPathComponent("reencoded-\(UUID()).aac")
        defer { try? FileManager.default.removeItem(at: dest) }

        let result = try await converter.convert(
            source: aacIntermediate, destination: dest
        )

        #expect(result.duration > 0.3)
        #expect(result.byteSize > 0)
        #expect(FileManager.default.fileExists(atPath: dest.path))
    }

    // MARK: - Error cases

    @Test("missing source throws sourceMissing")
    func missingSource() async throws {
        let missing = FileManager.default.temporaryDirectory
            .appendingPathComponent("no-such-file-\(UUID()).wav")
        let dest = FileManager.default.temporaryDirectory
            .appendingPathComponent("out-\(UUID()).aac")

        do {
            _ = try await converter.convert(
                source: missing, destination: dest
            )
            Issue.record("expected sourceMissing")
        } catch let error as ImportFailure {
            #expect(error == .sourceMissing)
        }
    }

    @Test("garbage bytes throws unreadable")
    func garbageBytes() async throws {
        let source = FileManager.default.temporaryDirectory
            .appendingPathComponent("garbage-\(UUID()).wav")
        try Data(repeating: 0xAB, count: 256).write(to: source)
        defer { try? FileManager.default.removeItem(at: source) }

        let dest = FileManager.default.temporaryDirectory
            .appendingPathComponent("out-\(UUID()).aac")
        defer { try? FileManager.default.removeItem(at: dest) }

        do {
            _ = try await converter.convert(
                source: source, destination: dest
            )
            Issue.record("expected unreadable or noAudio")
        } catch let error as ImportFailure {
            // Either unreadable or noAudio is acceptable -- the file has no
            // valid audio tracks.
            #expect(error == .unreadable || error == .noAudio)
        }
    }
}
