import Foundation
import LiveTranscriptModel
import Testing
import WhisperKit
@testable import LiveTranscription

/// The decoder's conversions, without a model.
@Suite("WhisperKitLiveDecoder")
struct WhisperKitLiveDecoderTests {
    private func segment(_ words: [WordTiming], noSpeechProb: Float = 0.1, avgLogprob: Float = -0.2) -> TranscriptionSegment {
        TranscriptionSegment(avgLogprob: avgLogprob, noSpeechProb: noSpeechProb, words: words)
    }

    private func timing(_ text: String, _ start: Float, _ end: Float, probability: Float = 0.9) -> WordTiming {
        WordTiming(word: text, tokens: [], start: start, end: end, probability: probability)
    }

    @Test("Segments that are likely silence and decoded with low confidence are dropped")
    func segmentsWithoutSpeechAreDropped() {
        let segments = [
            segment([timing(" um", 0, 0.5)], noSpeechProb: 0.7, avgLogprob: -1.2),
            segment([timing(" quiet", 0.5, 1)], noSpeechProb: 0.7, avgLogprob: -0.5),
            segment([timing(" unsure", 1, 1.5)], noSpeechProb: 0.3, avgLogprob: -1.5)
        ]
        let words = WhisperKitLiveDecoder.words(in: segments, windowStart: 0, windowEnd: 2)
        #expect(words.map(\.text) == [" quiet", " unsure"])
    }

    @Test("Word times move from the window to the recording timeline")
    func wordTimesMoveToTheRecordingTimeline() throws {
        let words = WhisperKitLiveDecoder.words(in: [segment([timing(" hello", 0.5, 1, probability: 0.4)])], windowStart: 100, windowEnd: 102)
        let hello = try #require(words.first)
        #expect(hello == TimedWord(text: " hello", start: 100.5, end: 101, probability: 0.4))
    }

    @Test("Words that run past the window end, and empty words, are dropped")
    func wordsEndingAfterTheWindowAreDropped() {
        let segments = [segment([timing(" ends", 1.5, 2), timing(" ", 2, 2), timing(" late", 1.9, 2.04)])]
        let words = WhisperKitLiveDecoder.words(in: segments, windowStart: 0, windowEnd: 2)
        #expect(words.map(\.text) == [" ends"])
    }

    @Test("Decoding options follow the live settings")
    func decodingOptionsFollowTheLiveSettings() {
        let english = WhisperKitLiveDecoder.decodingOptions(for: LiveDecodeOptions(language: "en", vocabularyPrompt: nil, settledContext: ""))
        #expect(english.language == "en")
        #expect(!english.detectLanguage)
        #expect(english.wordTimestamps)
        #expect(english.temperature == 0)
        #expect(english.temperatureFallbackCount == 0)
        #expect(english.skipSpecialTokens)
        #expect(english.suppressBlank)
        #expect(english.noSpeechThreshold == 0.6)
        #expect(english.compressionRatioThreshold == 2.4)
        #expect(english.logProbThreshold == -1.0)
        #expect(english.firstTokenLogProbThreshold == nil, "with no fallback, an unsure first token would empty the decode")

        let detect = WhisperKitLiveDecoder.decodingOptions(for: LiveDecodeOptions(language: nil, vocabularyPrompt: nil, settledContext: ""))
        #expect(detect.language == nil)
        #expect(detect.detectLanguage)
    }

    @Test("Words heard in the lead-in are dropped, and starts inside it move to the audio start")
    func leadInWordsAreDroppedAndStartsMoved() {
        let segments = [segment([timing(" um", 0.25, 0.75), timing(" yes", 0.5, 1.25), timing(" sure", 1.25, 1.375)])]
        let words = WhisperKitLiveDecoder.words(in: segments, audioStart: 10, leadIn: 1, windowEnd: 10.5)
        #expect(words == [
            TimedWord(text: " yes", start: 10, end: 10.25, probability: 0.9),
            TimedWord(text: " sure", start: 10.25, end: 10.375, probability: 0.9)
        ])
    }

    @Test("Windows WhisperKit would skip get leading silence")
    func shortWindowsGetLeadingSilence() {
        let options = WhisperKitLiveDecoder.decodingOptions(for: LiveDecodeOptions(language: "en", vocabularyPrompt: nil, settledContext: ""))
        let clip = TimeInterval(options.windowClipTime)
        #expect(WhisperKitLiveDecoder.shortestWindow > clip, "WhisperKit returns nothing for audio no longer than its clip")

        let short = Array(repeating: Float(0.1), count: 8000)
        let padded = WhisperKitLiveDecoder.withLeadIn(short)
        #expect(padded.leadIn == 1)
        #expect(padded.samples.count == 24000)
        #expect(padded.samples.prefix(16000).allSatisfy { $0 == 0 })
        #expect(Array(padded.samples.suffix(8000)) == short)

        let long = Array(repeating: Float(0.1), count: 32000)
        let unchanged = WhisperKitLiveDecoder.withLeadIn(long)
        #expect(unchanged.leadIn == 0)
        #expect(unchanged.samples == long)
    }

    @Test("The prompt keeps the vocabulary first and fills the rest with the latest context")
    func promptKeepsVocabularyFirstWithinTheLimit() {
        #expect(WhisperKitLiveDecoder.promptTokens(vocabulary: [1, 2, 3], context: [4, 5, 6, 7], limit: 5) == [1, 2, 3, 6, 7])
        #expect(WhisperKitLiveDecoder.promptTokens(vocabulary: [1, 2, 3], context: [4], limit: 2) == [1, 2])
        #expect(WhisperKitLiveDecoder.promptTokens(vocabulary: [], context: [4, 5], limit: 5) == [4, 5])
        #expect(WhisperKitLiveDecoder.promptTokenLimit == 111)
    }

    @Test("Without a prompt, neither the vocabulary nor the settled text reaches the decode")
    func noPromptSendsNoTokens() {
        let options = LiveDecodeOptions(language: "en", vocabularyPrompt: "Glossary: Rose.", settledContext: "the plan is")
        let encode: (String?) -> [Int] = { text in (text ?? "").split(separator: " ").map(\.count) }

        #expect(WhisperKitLiveDecoder.promptTokens(for: options, prompt: .none, encode: encode) == nil)
        #expect(WhisperKitLiveDecoder.promptTokens(for: options, prompt: .vocabularyAndSettledText, encode: encode) == [9, 5, 3, 4, 2])
        let empty = LiveDecodeOptions(language: "en", vocabularyPrompt: nil, settledContext: "")
        #expect(WhisperKitLiveDecoder.promptTokens(for: empty, prompt: .vocabularyAndSettledText, encode: encode) == nil, "an empty prompt is no prompt")
    }
}
