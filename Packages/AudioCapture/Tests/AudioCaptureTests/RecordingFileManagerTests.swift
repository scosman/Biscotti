import AVFoundation
import Foundation
import Testing
@testable import AudioCapture

@Suite("RecordingFileManager")
struct RecordingFileManagerTests {
    /// Creates a short PCM CAF file with a sine tone at the given URL.
    private func createTestCAF(at url: URL, sampleRate: Double = 24000, duration: Double = 0.5) throws {
        let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 1)
        // swiftlint:disable:next force_unwrapping
        let file = try AVAudioFile(forWriting: url, settings: format!.settings)
        let frameCount = AVAudioFrameCount(sampleRate * duration)
        // swiftlint:disable:next force_unwrapping
        let buffer = AVAudioPCMBuffer(pcmFormat: format!, frameCapacity: frameCount)!
        buffer.frameLength = frameCount
        // Fill with a 440 Hz sine tone
        // swiftlint:disable:next force_unwrapping
        let samples = buffer.floatChannelData![0]
        for idx in 0 ..< Int(frameCount) {
            samples[idx] = sinf(Float(idx) * 2.0 * .pi * 440.0 / Float(sampleRate))
        }
        try file.write(from: buffer)
    }

    /// Returns a temporary directory for a single test, cleaned up after.
    private func makeTempDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("AudioCaptureTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    @Test("encodeToM4A produces output file from valid CAF")
    func encodeProducesOutput() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let cafURL = dir.appendingPathComponent("test.caf")
        let m4aURL = dir.appendingPathComponent("test.m4a")

        try createTestCAF(at: cafURL)
        try RecordingFileManager.encodeToM4A(source: cafURL, destination: m4aURL)

        #expect(FileManager.default.fileExists(atPath: m4aURL.path))
        #expect(RecordingFileManager.fileSize(at: m4aURL) > 0)
    }

    @Test("encodeToM4A retains CAF on success")
    func cafRetainedOnSuccess() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let cafURL = dir.appendingPathComponent("test.caf")
        let m4aURL = dir.appendingPathComponent("test.m4a")

        try createTestCAF(at: cafURL)
        try RecordingFileManager.encodeToM4A(source: cafURL, destination: m4aURL)

        // Source CAF should still exist
        #expect(FileManager.default.fileExists(atPath: cafURL.path))
    }

    @Test("encodeToM4A throws conversionFailed for missing source")
    func throwsForMissingSource() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let cafURL = dir.appendingPathComponent("nonexistent.caf")
        let m4aURL = dir.appendingPathComponent("test.m4a")

        #expect(throws: CaptureError.self) {
            try RecordingFileManager.encodeToM4A(source: cafURL, destination: m4aURL)
        }
    }

    @Test("encodeToM4A throws conversionFailed for corrupt source")
    func throwsForCorruptSource() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let cafURL = dir.appendingPathComponent("corrupt.caf")
        let m4aURL = dir.appendingPathComponent("test.m4a")

        // Write garbage data as the CAF
        try Data("not a real audio file".utf8).write(to: cafURL)

        #expect(throws: CaptureError.self) {
            try RecordingFileManager.encodeToM4A(source: cafURL, destination: m4aURL)
        }

        // The source file should be retained (never deleted)
        #expect(FileManager.default.fileExists(atPath: cafURL.path))
    }

    @Test("fileSize returns size for existing file")
    func fileSizeExistingFile() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let url = dir.appendingPathComponent("test.dat")
        let data = Data(repeating: 0xAB, count: 1024)
        try data.write(to: url)

        #expect(RecordingFileManager.fileSize(at: url) == 1024)
    }

    @Test("fileSize returns 0 for missing file")
    func fileSizeMissingFile() {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("nonexistent-\(UUID().uuidString)")
        #expect(RecordingFileManager.fileSize(at: url) == 0)
    }

    @Test("formattedSize returns non-empty string")
    func formattedSizeReturnsString() {
        let result = RecordingFileManager.formattedSize(1024)
        #expect(!result.isEmpty)
    }

    @Test("encodeToM4A uses custom encoder settings")
    func customEncoderSettings() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let cafURL = dir.appendingPathComponent("test.caf")
        let m4aURL = dir.appendingPathComponent("test.m4a")

        try createTestCAF(at: cafURL, sampleRate: 48000)
        let custom = EncoderSettings(sampleRate: 48000, channels: 1, bitRate: 128_000)
        try RecordingFileManager.encodeToM4A(source: cafURL, destination: m4aURL, settings: custom)

        #expect(FileManager.default.fileExists(atPath: m4aURL.path))
        #expect(RecordingFileManager.fileSize(at: m4aURL) > 0)
    }
}
