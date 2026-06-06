import Foundation

/// Configuration for the speech processing pipeline (WhisperKit STT + SpeakerKit diarization).
public struct ProcessorConfig: Sendable, Codable, Equatable {
    /// WhisperKit model variant (e.g. "large-v3_turbo", "large-v3_turbo_1307MB").
    public let sttModel: String

    /// HuggingFace repo containing WhisperKit CoreML models.
    public let sttModelRepo: String

    /// Whether to include word-level timestamps in the transcription.
    public let enableWordTimestamps: Bool

    /// Strategy for merging diarization results with transcription.
    public let diarizationStrategy: DiarizationStrategy

    /// Load and unload STT and diarization models sequentially to reduce peak memory.
    /// Recommended for 8 GB Macs.
    public let sequentialLoading: Bool

    public init(
        sttModel: String = "large-v3_turbo",
        sttModelRepo: String = "argmaxinc/whisperkit-coreml",
        enableWordTimestamps: Bool = true,
        diarizationStrategy: DiarizationStrategy = .subsegment,
        sequentialLoading: Bool = false
    ) {
        self.sttModel = sttModel
        self.sttModelRepo = sttModelRepo
        self.enableWordTimestamps = enableWordTimestamps
        self.diarizationStrategy = diarizationStrategy
        self.sequentialLoading = sequentialLoading
    }

    public static let `default` = ProcessorConfig()
}

public extension ProcessorConfig {
    /// Picks the quantized `_1307MB` variant on <= 8 GB Macs, full-precision otherwise,
    /// and turns on sequentialLoading on <= 8 GB. Used as the production default.
    static func ramAware(
        physicalMemory: UInt64 = ProcessInfo.processInfo.physicalMemory
    ) -> ProcessorConfig {
        let eightGB: UInt64 = 8 * 1024 * 1024 * 1024
        let isLowMemory = physicalMemory <= eightGB

        return ProcessorConfig(
            sttModel: isLowMemory ? "large-v3_turbo_1307MB" : "large-v3_turbo",
            sequentialLoading: isLowMemory
        )
    }
}
