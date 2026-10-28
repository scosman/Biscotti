import LiveTranscription
import LiveTranscriptModel
import Testing

@Suite("LiveLanguage support")
struct LiveLanguageSupportTests {
    @Test("Whisper takes English, Detect and locales of languages it knows")
    func whisperSupportsEnglishDetectAndKnownLocales() {
        #expect(LiveLanguage.english.isSupportedByWhisper)
        #expect(LiveLanguage.detect.isSupportedByWhisper)
        #expect(LiveLanguage.locale("fr-FR").isSupportedByWhisper)
        #expect(LiveLanguage.locale("de").isSupportedByWhisper)
        #expect(!LiveLanguage.locale("tlh").isSupportedByWhisper)
        #expect(!LiveLanguage.locale("").isSupportedByWhisper)
    }
}
