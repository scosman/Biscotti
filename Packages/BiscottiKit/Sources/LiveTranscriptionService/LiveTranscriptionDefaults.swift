import Foundation
import LiveTranscriptModel

/// The live engine and its settings, chosen by the phase 5 replay experiment.
/// They are code constants, not user settings. The results and the reasons
/// for the choice are in `specs/research/live_transcription/README.md`.
/// The live Whisper prompt is `WhisperKitLiveDecoder.defaultPrompt`.
public enum LiveTranscriptionDefaults {
    public static let engine: LiveEngineKind = .whisper

    /// The Whisper model folder name.
    public static let whisperModel = "openai_whisper-small"

    /// The live model and its tokenizer on disk, in megabytes, for download offers.
    public static let whisperModelMegabytes = 464

    /// One track per source: "You" from the mic, "Others" from system audio.
    public static let tracks: [LiveTrack] = [.mic, .system]

    /// Seconds between decodes of one track. Both tracks share one decode
    /// lane, so while both talk a round holds two decodes; small's live
    /// decodes took a median 0.3 to 0.4 s on an M1 Max, and 1 s beat 2 s and
    /// 4 s on latency.
    public static let updateInterval: TimeInterval = 1

    /// A session config with the defaults. `vocabulary` is passed through for
    /// the record; the unprompted live decoder does not use it.
    public static func sessionConfig(
        sessionID: UUID,
        generation: Int,
        language: LiveLanguage,
        vocabulary: [String] = []
    ) -> LiveSessionConfig {
        LiveSessionConfig(
            sessionID: sessionID,
            generation: generation,
            engine: engine,
            whisperModel: whisperModel,
            tracks: tracks,
            updateInterval: updateInterval,
            language: language,
            vocabulary: vocabulary
        )
    }
}
