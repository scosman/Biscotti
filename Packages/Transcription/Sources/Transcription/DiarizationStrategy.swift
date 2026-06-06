/// Strategy for merging diarization speaker labels with transcription segments.
public enum DiarizationStrategy: String, Sendable, Codable, CaseIterable {
    /// Split transcription segments at word gaps and assign speakers to sub-segments.
    /// More granular; handles mid-segment speaker changes.
    case subsegment

    /// Assign one speaker to each full transcription segment.
    /// Simpler; works well when segments already correspond to single speakers.
    case segment
}
