import SpeakerKit

/// Diarization options for production transcription.
enum DiarizationSettings {
    /// Uses `.trainableOnly` centroid source so voiceprints are built only
    /// from windows where the speaker talks without much overlap. Some
    /// speakers may not receive a centroid; this is expected, not an error.
    static let options = PyannoteDiarizationOptions(centroidSource: .trainableOnly)
}
