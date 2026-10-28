import Foundation
import LiveTranscriptModel
import Testing
import Transcription
@testable import LiveTranscription

@Suite("WhisperLiveSession options and ending", .timeLimit(.minutes(1)))
struct WhisperLiveSessionLifecycleTests {
    // MARK: - Decode options

    @Test("Detect sends no language until a decode has words, then keeps that language")
    func detectLocksLanguageAfterFirstDecode() async throws {
        let clock = ManualClock()
        let decoder = FakeDecoder { call, index in
            let language = ["fr", "de"].indices.contains(index) ? ["fr", "de"][index] : "en"
            let heard = index == 0 ? [] : [word("hallo", 1.1, 1.4)]
            return LiveDecodeResult(hypothesis: call.hypothesis(heard), language: language)
        }
        let session = try await manualSession(decoder, clock: clock, config: config(language: .detect))

        await session.play(chunks(from: 0, to: 3), on: clock)
        await session.cancel()

        #expect(await decoder.calls.map(\.options.language) == [nil, nil, "de"])
        let reported = await session.collectedUpdates().map(\.detectedLanguage)
        #expect(reported.first == .some(nil))
        #expect(reported.last == "de")
    }

    @Test("The prompt carries the vocabulary and the settled text before the window")
    func promptCombinesVocabularyAndCommittedTail() async throws {
        let clock = ManualClock()
        let decoder = FakeDecoder(script: [
            word("Hello", 0.1, 0.4), word("there.", 0.6, 0.9), word("How", 1.6, 1.9), word("are", 2.1, 2.4), word("you", 2.6, 2.9)
        ])
        let vocabulary = ["Biscotti", "Argmax"]
        let session = try await manualSession(decoder, clock: clock, config: config(vocabulary: vocabulary))

        await session.play(chunks(from: 0, to: 3), on: clock)
        await session.cancel()

        let options = await decoder.calls.map(\.options)
        #expect(options.allSatisfy { $0.vocabularyPrompt == VocabularyFormatter.formatPrompt(from: vocabulary) })
        #expect(options.map(\.settledContext) == ["", "", "Hello there."], "Text joins the prompt once the window is trimmed past it")
        #expect(await decoder.calls.last?.startTime == 0.9)
    }

    @Test("An unsure last word stays out of the tail, but a final decode keeps it")
    func unsureLastWordStaysOutOfTheTailUntilTheFinalDecode() async throws {
        let clock = ManualClock()
        let decoder = FakeDecoder(script: [word("hello", 0.1, 0.4), word("maybe", 0.6, 0.9, probability: 0.2)])
        let session = try await manualSession(decoder, clock: clock)

        await session.play(chunks(from: 0, to: 1), on: clock)
        await session.append(chunks(from: 1, to: 1.25)[0])
        let final = await session.finish(timeout: .seconds(5))
        let streamed = await session.collectedUpdates()

        #expect(text(of: latestRows(streamed)) == "hello")
        #expect(text(of: latestRows(streamed + final)) == "hello maybe")
    }

    @Test("A config this session cannot run is rejected")
    func startValidatesTheConfig() async throws {
        let decoder = FakeDecoder()
        let session = WhisperLiveSession(decoder: decoder, scheduling: .manual)
        try await session.start(config())
        await #expect(throws: LiveSessionError.alreadyStarted) { try await session.start(config()) }

        for tracks: [LiveTrack] in [[], [.mic], [.mic, .mic], [.mixed, .mic]] {
            await #expect(throws: LiveSessionError.unsupportedTracks(tracks)) {
                try await WhisperLiveSession(decoder: decoder).start(config(tracks: tracks))
            }
        }
        for tracks: [LiveTrack] in [[.system, .mic], [.mixed]] {
            let accepted = WhisperLiveSession(decoder: decoder, scheduling: .manual)
            try await accepted.start(config(tracks: tracks))
            await accepted.cancel()
        }
        await #expect(throws: LiveSessionError.languageUnsupported("xx-YY")) {
            try await WhisperLiveSession(decoder: decoder).start(config(language: .locale("xx-YY")))
        }
        for interval in [0, -1, .nan, .infinity, 1e21] {
            await #expect(throws: LiveSessionError.invalidUpdateInterval) {
                try await WhisperLiveSession(decoder: decoder).start(config(interval: interval))
            }
        }
        await session.cancel()

        let clock = ManualClock()
        let french = try await manualSession(decoder, clock: clock, config: config(language: .locale("fr-FR")))
        await french.play(chunks(from: 0, to: 1), on: clock)
        await french.cancel()
        #expect(await decoder.calls.last?.options.language == "fr")
    }

    @Test("An update interval outside 0 to 60 seconds is ignored")
    func invalidUpdateIntervalIsIgnored() async throws {
        let clock = ManualClock()
        let decoder = FakeDecoder()
        let session = try await manualSession(decoder, clock: clock)
        for interval in [0, -1, .nan, .infinity, 1e21] {
            await session.setUpdateInterval(interval)
        }

        await session.play(chunks(from: 0, to: 2), on: clock)
        await session.cancel()
        #expect(await decoder.calls.map(\.windowEnd) == [1, 2], "The 1 s interval still applies")
    }
}
