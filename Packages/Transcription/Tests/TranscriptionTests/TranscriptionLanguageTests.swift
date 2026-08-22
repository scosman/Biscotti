import Testing
@testable import Transcription

@Suite("TranscriptionLanguage")
struct TranscriptionLanguageTests {
    @Test("auto has no Whisper code so the engine can turn detection on")
    func autoHasNoCode() {
        #expect(TranscriptionLanguage.auto.code == nil)
    }

    @Test("every other case carries its Whisper code as the raw value")
    func codesAreRawValues() {
        #expect(TranscriptionLanguage.russian.code == "ru")
        #expect(TranscriptionLanguage.english.code == "en")

        for language in TranscriptionLanguage.allCases where language != .auto {
            #expect(language.code == language.rawValue)
        }
    }

    @Test("auto sorts first in the picker order")
    func autoSortsFirst() {
        #expect(TranscriptionLanguage.allCases.first == .auto)
    }

    @Test("unknown stored strings fall back to auto")
    func unknownRawFallsBackToAuto() {
        #expect(TranscriptionLanguage(raw: "klingon") == .auto)
        #expect(TranscriptionLanguage(raw: "") == .auto)
        #expect(TranscriptionLanguage(raw: "ru") == .russian)
    }

    @Test("picker labels are English regardless of the system locale")
    func displayTextIsPopulated() {
        #expect(TranscriptionLanguage.auto.displayText == "Auto-Detect")
        #expect(TranscriptionLanguage.russian.displayText == "Russian")
        #expect(TranscriptionLanguage.english.displayText == "English")

        for language in TranscriptionLanguage.allCases {
            #expect(!language.displayText.isEmpty)
        }
    }
}
