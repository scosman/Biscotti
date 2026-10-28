import Foundation
import LiveTranscriptModel

/// Decodes one window of a track's audio for `WhisperLiveSession`.
///
/// `WhisperKitLiveDecoder` is the real one; tests use a fake, so the session
/// is tested without a model.
public protocol LiveDecoder: Sendable {
    /// - Parameters:
    ///   - samples: 16 kHz mono audio of the window.
    ///   - startTime: The window's start on the recording timeline.
    /// - Returns: Words with times on the recording timeline.
    func decode(_ samples: [Float], startTime: TimeInterval, options: LiveDecodeOptions) async throws -> LiveDecodeResult
}

/// What a decode needs besides the audio.
public struct LiveDecodeOptions: Sendable, Equatable {
    /// A Whisper language code such as "en", or nil to detect the language.
    public var language: String?
    /// The custom-vocabulary prompt, from `VocabularyFormatter`.
    public var vocabularyPrompt: String?
    /// Settled text that comes just before the window, so the decoder continues it.
    public var settledContext: String

    public init(language: String?, vocabularyPrompt: String?, settledContext: String) {
        self.language = language
        self.vocabularyPrompt = vocabularyPrompt
        self.settledContext = settledContext
    }
}

/// One decode's words and language.
///
/// The spec's decoder returns a bare `Hypothesis`. Detect mode also needs the
/// language the decoder identified, so it travels alongside.
public struct LiveDecodeResult: Sendable, Equatable {
    public var hypothesis: Hypothesis
    /// The language the decoder used or detected, as a Whisper language code.
    public var language: String?
    /// Where a description of a non-speech sound starts that the decode's
    /// last words leave open ("[BLANK" at the window's end). Its words are
    /// not in `hypothesis`; nothing from here on may settle yet, while a
    /// later decode can still hear the rest of it.
    public var openAnnotationStart: TimeInterval?
    /// With a description open, the words read as if its opener were stray,
    /// only the opener left out: what a decode that no later one can hear
    /// more than (in silence, at Stop, before a gap) keeps.
    public var wordsWithoutOpener: [TimedWord]?

    public init(
        hypothesis: Hypothesis,
        language: String?,
        openAnnotationStart: TimeInterval? = nil,
        wordsWithoutOpener: [TimedWord]? = nil
    ) {
        self.hypothesis = hypothesis
        self.language = language
        self.openAnnotationStart = openAnnotationStart
        self.wordsWithoutOpener = wordsWithoutOpener
    }
}
