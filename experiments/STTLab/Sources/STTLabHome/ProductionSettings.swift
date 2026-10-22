import Foundation

/// Production engine constants, copied from Packages/Transcription/Sources/Transcription/MethodResolver.swift.
/// A unit test asserts these match the production source, so drift is caught.
public enum ProductionSettings {
    /// The V1 STT model name. Must match MethodResolver.sttModel.
    public static let sttModel = "openai_whisper-large-v3-v20240930_626MB"

    /// The model repository for WhisperKit CoreML models.
    public static let sttModelRepo = "argmaxinc/whisperkit-coreml"

    /// Whether word-level timestamps are enabled in production.
    public static let enableWordTimestamps = true

    /// The diarization merge strategy used in production.
    public static let diarizationStrategy = "subsegment"

    /// The default download base directory (reuses the app's model cache).
    public static func downloadBase() -> URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Biscotti")
    }

    /// The pinned argmax-oss-swift version this experiment is built against.
    public static let argmaxVersion = "1.0.0"
}
