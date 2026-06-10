/// An opaque, extensible identity for a transcription configuration.
///
/// V1 offers no transcription options — one fixed method bakes in every
/// output-affecting parameter (STT model + quantization, diarization model,
/// diarization strategy, word-timestamps). The engine owns the id→settings
/// mapping; callers receive the id in ``TranscriptResult/transcriptionMethodId``.
///
/// Adding `v2` later is purely additive.
public struct TranscriptionMethod: Sendable, Equatable {
    /// The opaque method identifier (e.g. `"v1"`).
    public let id: String

    /// The fixed V1 method: WhisperKit large-v3-turbo + Pyannote v4 community-1,
    /// `.subsegment` diarization, word-timestamps on, RAM-aware quantization.
    public static let v1 = TranscriptionMethod(id: "v1") // swiftlint:disable:this identifier_name

    /// The current default method the engine uses.
    public static let current: TranscriptionMethod = .v1
}
