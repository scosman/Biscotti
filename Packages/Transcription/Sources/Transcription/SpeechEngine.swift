/// Which STT engine a transcription method uses.
public enum SpeechEngine: String, Codable, Sendable, CaseIterable {
    case whisper
    case apple
}

/// Separately downloadable model components managed by this package.
/// Apple assets are system-managed and are NOT a component.
public enum ModelComponent: String, Codable, Sendable, CaseIterable {
    /// WhisperKit STT model (models/argmaxinc/whisperkit-coreml/<model>).
    case whisper
    /// SpeakerKit diarization model (models/argmaxinc/speakerkit-coreml).
    case speakerID
}

public extension Set<ModelComponent> {
    /// All model components.
    static var all: Self {
        Set(ModelComponent.allCases)
    }
}

/// Per-call transcription configuration.
///
/// Carries the method identity and (for Apple) the locale. Callers that
/// pass `nil` get the engine's default method.
public struct TranscriptionConfig: Codable, Sendable, Equatable {
    /// Which transcription method to use.
    public let method: TranscriptionMethod

    /// Locale identifier for Apple (e.g. "en_US"). Ignored for Whisper.
    public let locale: String?

    public init(method: TranscriptionMethod, locale: String? = nil) {
        self.method = method
        self.locale = locale
    }

    /// Config for the current Whisper method.
    public static func whisper() -> TranscriptionConfig {
        TranscriptionConfig(method: .current, locale: nil)
    }

    /// Config for Apple Speech with a specific locale.
    public static func apple(locale: String) -> TranscriptionConfig {
        TranscriptionConfig(method: .appleV1, locale: locale)
    }

    /// The engine this config targets.
    public var engine: SpeechEngine {
        method.engine
    }
}
