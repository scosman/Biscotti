import Foundation
import Transcription

// MARK: - SpeechEnginePolicy

/// Which speech engine the app recommends and uses when the user hasn't chosen one.
public enum SpeechEnginePolicy {
    /// Whisper on every macOS version. Apple Speech stays opt-in on macOS 26+
    /// (Speech to Text Model sheet), but is never the implicit default.
    public static let recommended: SpeechEngine = .whisper
}

// MARK: - AppleLocalePolicy

/// Pure locale resolution and display logic for Apple Speech.
public enum AppleLocalePolicy {
    /// Resolves the default Apple locale per functional spec §6.2:
    /// 1. `equivalent` (the exact/equivalent match) if non-nil and in `supported`.
    /// 2. Else a supported locale whose language code matches `current`'s,
    ///    preferring the language's primary region (e.g. `fr_FR` for French).
    /// 3. Else `en_US`.
    public static func defaultLocale(
        current: Locale,
        supported: [String],
        equivalent: String?
    ) -> String {
        // 1. Exact/equivalent match
        if let equivalent, supported.contains(equivalent) {
            return equivalent
        }

        // 2. Same-language fallback
        let currentLanguage = current.language.languageCode?.identifier ?? ""
        let sameLanguage = supported.filter { id in
            Locale(identifier: id).language.languageCode?.identifier == currentLanguage
        }
        if !sameLanguage.isEmpty {
            // Prefer the language's "default region" locale
            let primaryRegion = Locale(languageCode: Locale.LanguageCode(currentLanguage))
            let primaryID = primaryRegion.identifier
            if sameLanguage.contains(primaryID) {
                return primaryID
            }
            return sameLanguage[0]
        }

        // 3. en_US fallback
        return "en_US"
    }

    /// Builds sorted display options from supported locale identifiers.
    public static func options(
        for supported: [String],
        displayLocale: Locale = .current
    ) -> [AppleLocaleOption] {
        supported.map { id in
            let displayName = displayLocale.localizedString(forIdentifier: id) ?? id
            let languageName = displayLocale.localizedString(
                forLanguageCode: Locale(identifier: id).language.languageCode?.identifier ?? ""
            ) ?? id
            return AppleLocaleOption(
                id: id,
                displayName: displayName,
                languageName: languageName
            )
        }
        .sorted { $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending }
    }
}
