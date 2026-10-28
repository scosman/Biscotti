import Foundation
import LiveTranscriptModel
import WhisperKit

/// What each live decode is prompted with.
public enum LiveDecoderPrompt: String, Sendable, CaseIterable {
    /// The spec's prompt: the vocabulary, then the most recent settled text.
    case vocabularyAndSettledText
    /// No prompt, so no vocabulary and no context. With argmax-oss-swift
    /// 1.1.0, a prompted decode on a multilingual model (large-v3, small) runs
    /// without WhisperKit's timestamp rules: `TimestampRulesFilter` looks for
    /// the task token among the first three tokens, and a prompt comes first.
    /// On meeting audio, prompted live decodes returned words timed past the
    /// window's end, which are dropped, or squeezed into its first second,
    /// which defeats duplicate removal. On a 60 s trial clip, before the fixture
    /// level and first-token fixes, the spec's prompt gave
    /// 38% WER against 26% unprompted. Restoring the rules for prompted
    /// decodes did not help (67%).
    case none
}

/// Decodes live windows with a loaded `WhisperKit`.
///
/// The worker hands it the engine's `WhisperKit` when the live and final
/// models match, so the model is loaded once. Otherwise it loads the live
/// model for this decoder alone and calls `unloadModels()` when the session ends.
public actor WhisperKitLiveDecoder: LiveDecoder {
    /// Segments more likely silence than speech, and decoded with low
    /// confidence, are dropped.
    static let noSpeechLimit: Float = 0.6
    static let logProbLimit: Float = -1.0
    /// The spec caps the prompt at 200 tokens. WhisperKit keeps only the last
    /// 111 of them, which would drop the vocabulary first, so the cap is
    /// WhisperKit's own limit.
    static let promptTokenLimit = min(200, Constants.maxTokenContext / 2 - 1)
    /// Word times are 20 ms apart, and a word that ends exactly at the window
    /// end must not be lost to rounding.
    static let windowEndTolerance: TimeInterval = 0.001
    /// WhisperKit's seek loop stops `windowClipTime` (1 s by default) before
    /// the end of the audio (`TranscribeTask`), so it returns nothing at all
    /// for 1 s of audio or less. Shorter windows get leading silence up to this
    /// length. `windowClipTime: 0` would not do: WhisperKit would then run a
    /// second, padded pass over whatever follows the last timestamp of every
    /// window, doubling the encoder cost and inviting words in silence.
    static let shortestWindow: TimeInterval = 1.5

    private let whisperKit: WhisperKit
    private let prompt: LiveDecoderPrompt

    // TODO(live vocabulary): when argmax-oss-swift keeps timestamp rules for
    // prompted decodes on multilingual models, re-measure
    // `.vocabularyAndSettledText` with the replay benchmark and switch if it
    // wins (`specs/research/live_transcription/README.md`).

    /// The prompt live decodes use unless the caller picks another: `.none`,
    /// the prompt every gated benchmark run measured
    /// (`specs/research/live_transcription/README.md`). Live Whisper therefore
    /// applies no custom vocabulary; the final pass still does.
    public static let defaultPrompt: LiveDecoderPrompt = .none

    public init(whisperKit: WhisperKit, prompt: LiveDecoderPrompt = defaultPrompt) {
        self.whisperKit = whisperKit
        self.prompt = prompt
    }

    /// Releases the model. Only for a model loaded for this decoder alone,
    /// once no decode is in flight.
    public func unloadModels() async {
        await whisperKit.unloadModels()
    }

    public func decode(_ samples: [Float], startTime: TimeInterval, options: LiveDecodeOptions) async throws -> LiveDecodeResult {
        var decoding = Self.decodingOptions(for: options)
        if let tokenizer = whisperKit.tokenizer {
            decoding.promptTokens = Self.promptTokens(for: options, prompt: prompt) { Self.encode($0, with: tokenizer) }
        }
        let (audio, leadIn) = Self.withLeadIn(samples)
        let results = try await whisperKit.transcribe(audioArray: audio, decodeOptions: decoding)
        let windowEnd = startTime + Double(samples.count) / LiveAudioChunk.sampleRate
        let spoken = Self.spokenWords(in: results.flatMap(\.segments), audioStart: startTime, leadIn: leadIn, windowEnd: windowEnd)
        return LiveDecodeResult(
            hypothesis: Hypothesis(words: spoken.words, windowStart: startTime, windowEnd: windowEnd),
            language: results.first?.language,
            openAnnotationStart: spoken.openFrom,
            wordsWithoutOpener: spoken.wordsWithoutOpener
        )
    }

    // MARK: - Pure helpers

    static func decodingOptions(for options: LiveDecodeOptions) -> DecodingOptions {
        var decoding = DecodingOptions(
            task: .transcribe,
            language: options.language,
            temperature: 0,
            temperatureFallbackCount: 0,
            detectLanguage: options.language == nil,
            skipSpecialTokens: true,
            wordTimestamps: true,
            suppressBlank: true,
            compressionRatioThreshold: 2.4,
            logProbThreshold: logProbLimit,
            noSpeechThreshold: noSpeechLimit
        )
        // Not in the spec's options table. WhisperKit's default (-1.5) ends a
        // decode whose first sampled token is unsure and asks for a fallback
        // at a higher temperature; with no fallback the window decodes to
        // nothing. On meeting audio that emptied about two decodes in three
        // of a long turn, so agreement never formed and the forced boundary
        // dropped the speech.
        decoding.firstTokenLogProbThreshold = nil
        return decoding
    }

    /// Prepends silence to a window shorter than `shortestWindow`.
    /// - Returns: The audio to decode and the seconds of silence added.
    static func withLeadIn(_ samples: [Float]) -> (samples: [Float], leadIn: TimeInterval) {
        let missing = Int(shortestWindow * LiveAudioChunk.sampleRate) - samples.count
        guard missing > 0 else { return (samples, 0) }
        return (Array(repeating: 0, count: missing) + samples, Double(missing) / LiveAudioChunk.sampleRate)
    }

    /// The decode's prompt tokens, or nil for no prompt.
    static func promptTokens(for options: LiveDecodeOptions, prompt: LiveDecoderPrompt, encode: (String?) -> [Int]) -> [Int]? {
        guard prompt == .vocabularyAndSettledText else { return nil }
        let tokens = promptTokens(vocabulary: encode(options.vocabularyPrompt), context: encode(options.settledContext), limit: promptTokenLimit)
        return tokens.isEmpty ? nil : tokens
    }

    /// The vocabulary first, then as much of the most recent context as fits.
    static func promptTokens(vocabulary: [Int], context: [Int], limit: Int) -> [Int] {
        let kept = vocabulary.prefix(limit)
        return Array(kept) + context.suffix(limit - kept.count)
    }

    /// Word timings on the recording timeline, without likely-silent segments
    /// and without words that run past the window.
    /// - Parameter windowStart: Where the decoded audio starts, lead-in included.
    static func words(in segments: [TranscriptionSegment], windowStart: TimeInterval, windowEnd: TimeInterval) -> [TimedWord] {
        segments
            .filter { !($0.noSpeechProb > noSpeechLimit && $0.avgLogprob < logProbLimit) }
            .flatMap { $0.words ?? [] }
            .map { TimedWord(text: $0.word, start: windowStart + Double($0.start), end: windowStart + Double($0.end), probability: $0.probability) }
            .filter { $0.end <= windowEnd + windowEndTolerance && !$0.text.trimmingCharacters(in: .whitespaces).isEmpty }
    }

    /// The words a decode returns: those heard in the real audio, without
    /// descriptions of sounds that are not speech (`NonSpeechAnnotations`).
    static func spokenWords(in segments: [TranscriptionSegment], audioStart: TimeInterval, leadIn: TimeInterval, windowEnd: TimeInterval) -> NonSpeechAnnotations.Filtered {
        NonSpeechAnnotations.removed(from: words(in: segments, audioStart: audioStart, leadIn: leadIn, windowEnd: windowEnd))
    }

    /// Words heard in the real audio of a window decoded with `leadIn` seconds
    /// of added silence: a word that ends inside the silence is dropped, and a
    /// start inside it moves to `audioStart`, so the next decode agrees with it.
    static func words(in segments: [TranscriptionSegment], audioStart: TimeInterval, leadIn: TimeInterval, windowEnd: TimeInterval) -> [TimedWord] {
        words(in: segments, windowStart: audioStart - leadIn, windowEnd: windowEnd)
            .filter { $0.end > audioStart }
            .map { word in
                var word = word
                word.start = max(word.start, audioStart)
                return word
            }
    }

    /// Encodes as WhisperKit's own CLI does: a leading space, no special tokens.
    private static func encode(_ text: String?, with tokenizer: any WhisperTokenizer) -> [Int] {
        guard let trimmed = text?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty else { return [] }
        return tokenizer.encode(text: " " + trimmed).filter { $0 < tokenizer.specialTokens.specialTokenBegin }
    }
}
