import Foundation
import WhisperKit

/// Shared audio-loading utilities used by both ``InProcessTranscriptionEngine``
/// and ``SpeakerAnalyzer``.
enum AudioLoading {
    /// Load audio samples from a file path as a Float array at 16 kHz mono.
    static func loadSamples(fromPath path: String) throws -> [Float] {
        guard FileManager.default.fileExists(atPath: path) else {
            throw TranscriptionError.invalidInput("Audio file does not exist: \(path)")
        }
        do {
            let samples = try AudioProcessor.loadAudioAsFloatArray(fromPath: path)
            guard !samples.isEmpty else {
                throw TranscriptionError.invalidInput(
                    "Audio file produced zero samples: \(path)"
                )
            }
            return samples
        } catch let error as TranscriptionError {
            throw error
        } catch {
            throw TranscriptionError.invalidInput(
                "Failed to load audio from \(path): \(error.localizedDescription)"
            )
        }
    }

    /// Load and merge mic + system audio into a single sample buffer.
    struct MergeResult {
        let samples: [Float]
        let duration: TimeInterval
    }

    /// Load the mic stream and, when present, the system stream, then merge.
    ///
    /// A `nil` `systemPath` means a single-track source (e.g. an imported audio
    /// file stored as the mic track): only the mic stream is loaded and
    /// ``AudioMerger`` passes it through as-is.
    static func loadAndMerge(
        micPath: String, systemPath: String?
    ) throws -> MergeResult {
        let micSamples = try loadSamples(fromPath: micPath)
        let systemSamples = try systemPath.map { try loadSamples(fromPath: $0) } ?? []
        let merged = try AudioMerger.merge(mic: micSamples, system: systemSamples)
        return MergeResult(samples: merged.samples, duration: merged.duration)
    }
}
