import Foundation
import LiveTranscriptModel
import WhisperKit

/// A live session's language, as Whisper takes it.
enum WhisperLanguage: Equatable {
    /// A Whisper language code, such as "en".
    case fixed(String)
    /// Detect from the first decode with words, then keep that language.
    case detect

    init(_ language: LiveLanguage) throws(LiveSessionError) {
        switch language {
        case .english:
            self = .fixed("en")
        case .detect:
            self = .detect
        case let .locale(identifier):
            guard let code = Locale(identifier: identifier).language.languageCode?.identifier,
                  Constants.languages.values.contains(code)
            else {
                throw .languageUnsupported(identifier)
            }
            self = .fixed(code)
        }
    }

    var code: String? {
        if case let .fixed(code) = self { code } else { nil }
    }
}

public extension LiveLanguage {
    /// Whether the live Whisper session accepts this language. The app checks
    /// it before a start: the session's `LiveSessionError.languageUnsupported`
    /// reaches the app from the worker only as `transcriptionFailed`.
    var isSupportedByWhisper: Bool {
        (try? WhisperLanguage(self)) != nil
    }
}
