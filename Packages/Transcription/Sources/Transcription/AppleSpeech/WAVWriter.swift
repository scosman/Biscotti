import AVFoundation
import Foundation

/// Writes a `[Float]` audio buffer to a temporary WAV file at 16 kHz mono.
///
/// Apple's `SpeechAnalyzer.analyzeSequence(from:)` takes an `AVAudioFile`,
/// not a raw buffer. This writer creates the temp file the engine feeds
/// to the analyzer. The caller is responsible for deleting the file after use.
public enum WAVWriter {
    /// Write 16 kHz mono float samples to a new temporary `.wav` file.
    ///
    /// - Parameter samples: PCM float samples at 16 kHz.
    /// - Returns: URL of the written WAV file. The caller must delete it.
    /// - Throws: If the file cannot be created or written.
    public static func writeTemp(_ samples: [Float]) throws -> URL {
        let tempDir = FileManager.default.temporaryDirectory
        let url = tempDir.appendingPathComponent(
            "biscotti-apple-stt-\(UUID().uuidString).wav"
        )

        let sampleRate: Double = 16000
        guard let format = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: sampleRate,
            channels: 1,
            interleaved: false
        ) else {
            throw TranscriptionError.invalidInput("Cannot create 16 kHz mono audio format")
        }

        let file = try AVAudioFile(
            forWriting: url,
            settings: format.settings,
            commonFormat: .pcmFormatFloat32,
            interleaved: false
        )

        let frameCount = AVAudioFrameCount(samples.count)
        guard let buffer = AVAudioPCMBuffer(
            pcmFormat: format,
            frameCapacity: frameCount
        ) else {
            throw TranscriptionError.invalidInput("Cannot create audio buffer")
        }
        buffer.frameLength = frameCount

        // Copy samples into the buffer's channel data.
        if let channelData = buffer.floatChannelData {
            samples.withUnsafeBufferPointer { src in
                guard let base = src.baseAddress else { return }
                channelData[0].update(from: base, count: samples.count)
            }
        }

        try file.write(from: buffer)
        return url
    }
}
