import Foundation

/// Errors from the ArgMaxKit processing pipeline.
public enum ArgMaxError: Error, LocalizedError, Sendable {
    /// The audio file does not exist or is not a supported format.
    case invalidAudioFile(URL, underlying: String)

    /// Failed to load audio samples from the file.
    case audioLoadFailed(URL, underlying: String)

    /// WhisperKit model loading or initialization failed.
    case modelLoadFailed(String)

    /// WhisperKit transcription returned an error.
    case transcriptionFailed(String)

    /// SpeakerKit diarization returned an error.
    case diarizationFailed(String)

    public var errorDescription: String? {
        switch self {
        case .invalidAudioFile(let url, let reason):
            return "Invalid audio file at \(url.path): \(reason)"
        case .audioLoadFailed(let url, let reason):
            return "Failed to load audio from \(url.path): \(reason)"
        case .modelLoadFailed(let reason):
            return "Failed to load ML models: \(reason)"
        case .transcriptionFailed(let reason):
            return "Transcription failed: \(reason)"
        case .diarizationFailed(let reason):
            return "Diarization failed: \(reason)"
        }
    }
}
