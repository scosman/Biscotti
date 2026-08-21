import Foundation

/// The spoken language the STT model is told to expect.
///
/// `.auto` asks WhisperKit to detect the language from the first audio window.
/// Every other case pins the decoder to that language, which both skips the
/// detection pass and guarantees the transcript comes back in the language that
/// was spoken.
///
/// Pinning matters because WhisperKit's own default is neither of those: with
/// no language and detection off it prefills the `<|en|>` token, so non-English
/// speech is transcribed *into English*. `.auto` therefore has to turn
/// `DecodingOptions.detectLanguage` on explicitly -- see
/// ``InProcessTranscriptionEngine``.
///
/// Raw values are the Whisper language codes, so the stored settings string is
/// the code itself.
public enum TranscriptionLanguage: String, CaseIterable, Sendable, Codable, Identifiable {
    case auto
    case arabic = "ar"
    case chinese = "zh"
    case dutch = "nl"
    case english = "en"
    case french = "fr"
    case german = "de"
    case hindi = "hi"
    case italian = "it"
    case japanese = "ja"
    case korean = "ko"
    case polish = "pl"
    case portuguese = "pt"
    case russian = "ru"
    case spanish = "es"
    case turkish = "tr"
    case ukrainian = "uk"

    public var id: String {
        rawValue
    }

    /// The Whisper language code, or `nil` for `.auto` (meaning "detect it").
    public var code: String? {
        self == .auto ? nil : rawValue
    }

    /// Human-readable label for the picker. Derived from the code rather than a
    /// hand-written table, so adding a language only takes one line above.
    ///
    /// Resolved against a fixed English locale, not `Locale.current`: the rest
    /// of the UI is English, and a picker that renamed itself with the system
    /// language would be the only screen that did.
    public var displayText: String {
        guard let code else { return "Auto-Detect" }
        return Self.labelLocale.localizedString(forLanguageCode: code) ?? code
    }

    private static let labelLocale = Locale(identifier: "en_US")

    /// Stored-string -> enum, defaulting to `.auto` for unknown values.
    public init(raw: String) {
        self = Self(rawValue: raw) ?? .auto
    }
}
