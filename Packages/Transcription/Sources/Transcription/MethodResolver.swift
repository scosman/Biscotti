import Foundation

/// Internal settings resolved from a ``TranscriptionMethod``.
///
/// The method resolver maps an opaque method identity to concrete engine
/// parameters. RAM-aware quantization and sequential loading are internal
/// details — callers never see these settings.
struct ResolvedMethodSettings: Equatable {
    let sttModel: String
    let sttModelRepo: String
    let enableWordTimestamps: Bool
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
    /// The default STT model (full-precision, ~3.1 GB).
    static let defaultModel = "openai_whisper-large-v3_turbo"
    /// The quantized STT model for low-RAM Macs (~1.3 GB).
    static let quantizedModel = "openai_whisper-large-v3_turbo_1307MB"
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
        default:
            // Unknown methods fall back to v1 behavior.
            resolveV1(physicalMemory: physicalMemory)
        }
    }

    // MARK: - V1

    private static func resolveV1(physicalMemory: UInt64) -> ResolvedMethodSettings {
        let eightGB: UInt64 = 8 * 1024 * 1024 * 1024
        let isLowRAM = physicalMemory <= eightGB

        return ResolvedMethodSettings(
            sttModel: isLowRAM ? quantizedModel : defaultModel,
            sttModelRepo: defaultRepo,
            enableWordTimestamps: true,
            diarizationStrategy: .subsegment,
            sequentialLoading: isLowRAM
        )
    }
}
