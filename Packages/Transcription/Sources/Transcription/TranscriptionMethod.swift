/// An opaque, extensible identity for a transcription configuration.
///
/// There are no transcription options — each fixed method bakes in every
/// output-affecting parameter (STT model, diarization model, diarization
/// strategy, word-timestamps, language detection). The engine owns the
/// id→settings mapping; callers receive the id in
/// ``TranscriptResult/transcriptionMethodId``.
///
/// Adding a new method later is purely additive.
public struct TranscriptionMethod: Sendable, Equatable, Codable {
    /// The opaque method identifier (e.g. `"v1"`).
    public let id: String

    /// The original method: WhisperKit large-v3 (Sept 2024, 626 MB) +
    /// Pyannote v4 community-1, `.subsegment` diarization, word-timestamps on,
    /// sequential loading on low-RAM Macs, language detection off (English).
    public static let v1 = TranscriptionMethod(id: "v1") // swiftlint:disable:this identifier_name

    /// The current method: `v1` settings plus Whisper language detection, so
    /// non-English audio is transcribed in its spoken language.
    public static let v2 = TranscriptionMethod(id: "v2") // swiftlint:disable:this identifier_name

    /// Apple Speech method: SpeechTranscriber on macOS 26+. Words are grouped
    /// from attributed-string runs; diarization uses SpeakerKit (same as Whisper).
    public static let appleV1 = TranscriptionMethod(id: "apple-v1")

    /// The current default method the engine uses.
    public static let current: TranscriptionMethod = .v2

    /// Which STT engine this method uses.
    public var engine: SpeechEngine {
        id.hasPrefix("apple") ? .apple : .whisper
    }
}
