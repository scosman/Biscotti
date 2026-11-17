import Foundation
import Testing
import Transcription
import TranscriptionService

// MARK: - SpeechEnginePolicy

@Suite("SpeechEnginePolicy")
struct SpeechEnginePolicyTests {
    @Test("recommends whisper for new users")
    func recommendsWhisper() {
        #expect(SpeechEnginePolicy.recommended == .whisper)
    }
}

// MARK: - AppleLocalePolicy

@Suite("AppleLocalePolicy")
struct AppleLocalePolicyTests {
    @Test("defaultLocale returns equivalent when present in supported")
    func defaultLocaleReturnsEquivalent() {
        let result = AppleLocalePolicy.defaultLocale(
            current: Locale(identifier: "en_US"),
            supported: ["en_US", "fr_FR", "de_DE"],
            equivalent: "en_US"
        )
        #expect(result == "en_US")
    }

    @Test("defaultLocale returns same-language fallback when equivalent is nil")
    func defaultLocaleSameLanguageFallback() {
        let result = AppleLocalePolicy.defaultLocale(
            current: Locale(identifier: "fr_CA"),
            supported: ["en_US", "fr_FR", "de_DE"],
            equivalent: nil
        )
        #expect(result == "fr_FR")
    }

    @Test("defaultLocale returns en_US when no match")
    func defaultLocaleEnUSFallback() {
        let result = AppleLocalePolicy.defaultLocale(
            current: Locale(identifier: "ja_JP"),
            supported: ["en_US", "fr_FR", "de_DE"],
            equivalent: nil
        )
        #expect(result == "en_US")
    }

    @Test("options returns sorted AppleLocaleOption values")
    func optionsSorted() {
        let result = AppleLocalePolicy.options(
            for: ["fr_FR", "de_DE", "en_US"],
            displayLocale: Locale(identifier: "en_US")
        )
        #expect(result.count == 3)
        // Sorted by displayName: English, French, German
        #expect(result[0].id == "en_US")
        #expect(result[1].id == "fr_FR")
        #expect(result[2].id == "de_DE")

        // Each option has non-empty displayName and languageName
        for option in result {
            #expect(!option.displayName.isEmpty)
            #expect(!option.languageName.isEmpty)
        }
    }
}
