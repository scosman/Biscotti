import Foundation

/// Internal settings resolved from a ``TranscriptionMethod``.
///
/// The method resolver maps an opaque method identity to concrete engine
/// parameters. Sequential loading is an internal detail — callers never
/// see these settings.
struct ResolvedMethodSettings: Equatable {
    let engine: SpeechEngine
    let sttModel: String
    let sttModelRepo: String
    let enableWordTimestamps: Bool
    let detectLanguage: Bool
    let diarizationStrategy: DiarizationStrategyInternal
    let sequentialLoading: Bool
}

/// Diarization merge strategy — internal to the engine, not public API.
enum DiarizationStrategyInternal: String, Equatable {
    case subsegment
    case segment
}

/// Resolves a ``TranscriptionMethod`` into concrete engine settings.
enum MethodResolver {
    /// The V1 STT model (Sept 2024 large-v3, quantized ~626 MB).
    static let sttModel = "openai_whisper-large-v3-v20240930_626MB"
    /// The default model repository.
    static let defaultRepo = "argmaxinc/whisperkit-coreml"

    /// Resolve a method to its concrete settings, factoring in available RAM.
    ///
    /// - Parameters:
    ///   - method: The transcription method to resolve.
    ///   - physicalMemory: Physical memory in bytes (defaults to the current machine).
    /// - Returns: Fully resolved settings the engine can use directly.
    static func resolve(
        _ method: TranscriptionMethod,
        physicalMemory: UInt64 = ProcessInfo.processInfo.physicalMemory
    ) -> ResolvedMethodSettings {
        switch method.id {
        case "v1":
            resolveV1(physicalMemory: physicalMemory)
        case "v2":
            resolveV2(physicalMemory: physicalMemory)
        case "apple-v1":
            resolveAppleV1(physicalMemory: physicalMemory)
        default:
            // Unknown methods fall back to v1 behavior.
            resolveV1(physicalMemory: physicalMemory)
        }
    }

    // MARK: - V1

    private static func resolveV1(physicalMemory: UInt64) -> ResolvedMethodSettings {
        whisperSettings(physicalMemory: physicalMemory, detectLanguage: false)
    }

    // MARK: - V2

    private static func resolveV2(physicalMemory: UInt64) -> ResolvedMethodSettings {
        whisperSettings(physicalMemory: physicalMemory, detectLanguage: true)
    }

    // MARK: - Apple V1

    private static func resolveAppleV1(physicalMemory: UInt64) -> ResolvedMethodSettings {
        let eightGB: UInt64 = 8 * 1024 * 1024 * 1024
        let isLowRAM = physicalMemory <= eightGB

        return ResolvedMethodSettings(
            engine: .apple,
            sttModel: sttModel,
            sttModelRepo: defaultRepo,
            enableWordTimestamps: true,
            detectLanguage: false,
            diarizationStrategy: .subsegment,
            sequentialLoading: isLowRAM
        )
    }

    private static func whisperSettings(
        physicalMemory: UInt64,
        detectLanguage: Bool
    ) -> ResolvedMethodSettings {
        let eightGB: UInt64 = 8 * 1024 * 1024 * 1024
        let isLowRAM = physicalMemory <= eightGB

        return ResolvedMethodSettings(
            engine: .whisper,
            sttModel: sttModel,
            sttModelRepo: defaultRepo,
            enableWordTimestamps: true,
            detectLanguage: detectLanguage,
            diarizationStrategy: .subsegment,
            sequentialLoading: isLowRAM
        )
    }
}
