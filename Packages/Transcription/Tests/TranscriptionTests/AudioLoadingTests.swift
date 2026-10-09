import AVFoundation
import Foundation
import Testing
@testable import Transcription

@Suite("AudioLoading - single and dual track")
struct AudioLoadingTests {
    /// Writes a short mono 16 kHz WAV of a constant-amplitude tone and returns its path.
    private func makeWAV(seconds: Double, amplitude: Float = 0.25) throws -> String {
        let sampleRate = 16000.0
        let frameCount = AVAudioFrameCount(seconds * sampleRate)
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("audio-loading-\(UUID().uuidString).wav")
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: sampleRate,
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 32,
            AVLinearPCMIsFloatKey: true
        ]
        let file = try AVAudioFile(forWriting: url, settings: settings)
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: frameCount))
        buffer.frameLength = frameCount
        let channel = try #require(buffer.floatChannelData?[0])
        for index in 0 ..< Int(frameCount) {
            channel[index] = amplitude * Float(sin(Double(index) * 0.05))
        }
        try file.write(from: buffer)
        return url.path
    }

    @Test("loadAndMerge with a nil system path loads only the mic track")
    func micOnlyLoadsSingleTrack() throws {
        let micPath = try makeWAV(seconds: 1.0)
        defer { try? FileManager.default.removeItem(atPath: micPath) }

        let result = try AudioLoading.loadAndMerge(micPath: micPath, systemPath: nil)

        #expect(abs(result.duration - 1.0) < 0.01)
        #expect(!result.samples.isEmpty)
    }

    @Test("Single-track result matches the mic samples exactly")
    func micOnlyMatchesMicSamples() throws {
        let micPath = try makeWAV(seconds: 0.5)
        defer { try? FileManager.default.removeItem(atPath: micPath) }

        let mic = try AudioLoading.loadSamples(fromPath: micPath)
        let result = try AudioLoading.loadAndMerge(micPath: micPath, systemPath: nil)

        #expect(result.samples == mic)
    }

    @Test("loadAndMerge with both tracks still merges to the longer duration")
    func twoTracksStillMerge() throws {
        let micPath = try makeWAV(seconds: 1.0)
        let systemPath = try makeWAV(seconds: 2.0)
        defer {
            try? FileManager.default.removeItem(atPath: micPath)
            try? FileManager.default.removeItem(atPath: systemPath)
        }

        let result = try AudioLoading.loadAndMerge(micPath: micPath, systemPath: systemPath)

        #expect(abs(result.duration - 2.0) < 0.01)
    }

    @Test("A missing mic file throws invalidInput even without a system track")
    func missingMicThrows() {
        #expect(throws: TranscriptionError.self) {
            _ = try AudioLoading.loadAndMerge(
                micPath: "/nonexistent/\(UUID().uuidString).wav", systemPath: nil
            )
        }
    }

    @Test("A provided but missing system file still throws")
    func missingSystemThrows() throws {
        let micPath = try makeWAV(seconds: 0.5)
        defer { try? FileManager.default.removeItem(atPath: micPath) }

        #expect(throws: TranscriptionError.self) {
            _ = try AudioLoading.loadAndMerge(
                micPath: micPath, systemPath: "/nonexistent/\(UUID().uuidString).wav"
            )
        }
    }
}
