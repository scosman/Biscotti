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
