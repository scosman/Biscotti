import Foundation
import LiveTranscriptModel
import Testing
@testable import LiveTranscription

@Suite("WhisperLiveSession silence", .timeLimit(.minutes(1)))
struct WhisperLiveSessionSilenceTests {
    @Test("Silence confirms the tail once, then skips decodes while settling the time")
    func silenceSkipsDecodesAndConfirmsTail() async throws {
        let clock = ManualClock()
        let decoder = FakeDecoder(script: [word("hello", 0.1, 0.4), word("there", 0.6, 0.9), word("friend", 1.6, 1.9)])
        let session = try await manualSession(decoder, clock: clock)

        await session.play(chunks(from: 0, to: 2) + chunks(from: 2, to: 6, level: Level.silence), on: clock)
        let final = await session.finish(timeout: .seconds(5))
        let streamed = await session.collectedUpdates()

        #expect(await decoder.calls.map(\.windowEnd) == [1, 2, 3], "The third decode is the confirming one")
        #expect(text(of: latestRows(streamed + final)) == "hello there friend")
        #expect(streamed.map(\.settledThrough).suffix(3) == [4, 5, 6])
        #expect(streamed.map(\.transcribedThrough).suffix(3) == [4, 5, 6])
    }

    @Test("A tail still unconfirmed after two seconds of silence is committed without another decode")
    func unconfirmedTailIsCommittedAfterTwoSecondsOfSilence() async throws {
        let clock = ManualClock()
        let decoder = FakeDecoder { call, index in
            let last = index >= 2 ? word("friends", 1.6, 1.9) : word("friend", 1.6, 1.9)
            let heard = [word("hello", 0.1, 0.4), word("there", 0.6, 0.9), last].filter { $0.end <= call.windowEnd }
            return LiveDecodeResult(hypothesis: call.hypothesis(heard), language: "en")
        }
        let session = try await manualSession(decoder, clock: clock)

        await session.play(chunks(from: 0, to: 2) + chunks(from: 2, to: 4, level: Level.silence), on: clock)
        await session.cancel()
        let rows = await latestRows(session.collectedUpdates())

        #expect(await decoder.calls.count == 3)
        #expect(text(of: rows) == "hello there friends")
        let allClosed = rows.allSatisfy(\.isClosed)
        #expect(allClosed)
    }

    @Test("A short quiet word in seconds of silence is decoded, not averaged away")
    func quietShortWordIsNotSkipped() async throws {
        let clock = ManualClock()
        let decoder = FakeDecoder(script: [word("no", 1.5, 1.7)])
        let session = try await manualSession(decoder, clock: clock, config: config(interval: 4))

        let quietWord = chunks(from: 1.5, to: 1.75, level: 0.02)
        await session.play(chunks(from: 0, to: 1.5, level: Level.silence) + quietWord + chunks(from: 1.75, to: 4, level: Level.silence), on: clock)
        let final = await session.finish(timeout: .seconds(5))
        let streamed = await session.collectedUpdates()

        #expect(await decoder.calls.map(\.windowEnd) == [4])
        #expect(text(of: latestRows(streamed + final)) == "no")
    }

    @Test("Noise that crosses the threshold now and then still lets the tail settle")
    func sparseNoiseStillSettlesTheTail() async throws {
        let clock = ManualClock()
        let decoder = FakeDecoder(script: [word("hello", 0.1, 0.4), word("there", 0.6, 0.9)])
        let session = try await manualSession(decoder, clock: clock)

        // A quiet click (−40 dBFS) ends every second. Averaged, the noise is
        // below −45 dBFS, yet it never leaves a full second of silent chunks.
        let noise = (0 ..< 50).flatMap { second in
            let start = 1 + Double(second)
            return chunks(from: start, to: start + 0.75, level: Level.silence) + chunks(from: start + 0.75, to: start + 1, level: 0.01)
        }
        await session.play(chunks(from: 0, to: 1) + noise, on: clock)
        await session.cancel()

        let updates = await session.collectedUpdates()
        let rows = latestRows(updates)
        let tailsSettled = rows.allSatisfy(\.tailText.isEmpty)
        #expect(text(of: rows) == "hello there")
        #expect(tailsSettled)
        #expect(updates.flatMap(\.gaps).isEmpty, "No overflow: decodes kept up")
        #expect(abs((updates.last?.transcribedThrough ?? 0) - 51) < 0.001)
    }

    @Test("A late pass decodes the speech before a silence instead of committing over it")
    func lateTailCommitWaitsForAConfirmingDecode() async throws {
        let clock = ManualClock()
        let decoder = FakeDecoder(script: [
            word("one", 0.1, 0.4), word("two", 0.6, 0.9), word("three", 1.1, 1.4), word("four", 2.1, 2.4)
        ])
        let session = try await manualSession(decoder, clock: clock)
        await session.play(chunks(from: 0, to: 1.75), on: clock)
        await session.append(chunks(from: 1.75, to: 2)[0])
        clock.advance(bySeconds: 0.25)

        // The decode at 2 s is slow: "four" and then 2.5 s of silence arrive meanwhile.
        await decoder.hold()
        let slowPass = Task { await session.runScheduledWork() }
        #expect(await eventually { await decoder.heldCount == 1 })
        for chunk in chunks(from: 2, to: 2.5) + chunks(from: 2.5, to: 5, level: Level.silence) {
            await session.append(chunk)
        }
        clock.advance(bySeconds: 3)
        await decoder.release()
        await slowPass.value

        await session.runScheduledWork()
        await session.play(chunks(from: 5, to: 5.25, level: Level.silence), on: clock)
        await session.cancel()

        #expect(await decoder.calls.map(\.windowEnd) == [1, 2, 5], "The confirming decode hears \"four\"")
        let updates = await session.collectedUpdates()
        #expect(text(of: latestRows(updates)) == "one two three four")
        #expect(updates.flatMap(\.gaps).isEmpty)
    }

    @Test("An unsure last word before a pause is kept by the decode that confirms the silence")
    func unsureLastWordBeforeAPauseIsKept() async throws {
        let clock = ManualClock()
        let decoder = FakeDecoder(script: [word("hello", 0.1, 0.4), word("maybe", 1.1, 1.4, probability: 0.2)])
        let session = try await manualSession(decoder, clock: clock)

        await session.play(chunks(from: 0, to: 1.5) + chunks(from: 1.5, to: 4, level: Level.silence), on: clock)
        await session.cancel()

        #expect(await decoder.calls.map(\.windowEnd) == [1, 2, 2.5], "Silence is not skipped while the word is held back")
        #expect(await text(of: latestRows(session.collectedUpdates())) == "hello maybe")
    }

    @Test("While a word is held back, settledThrough stays before it")
    func heldBackWordKeepsSettledThroughBeforeIt() async throws {
        let clock = ManualClock()
        let decoder = FakeDecoder(script: [word("hello", 0.1, 0.4), word("maybe", 1.1, 1.4, probability: 0.2)])
        let session = try await manualSession(decoder, clock: clock)

        await session.play(chunks(from: 0, to: 1.5) + chunks(from: 1.5, to: 4, level: Level.silence), on: clock)
        await session.cancel()

        let updates = await session.collectedUpdates()
        let beforeMaybeSettles = updates.prefix { update in !update.rows.contains { $0.settledText.contains("maybe") } }
        #expect(beforeMaybeSettles.count == 3)
        #expect(beforeMaybeSettles.map(\.settledThrough).max() == 1.1, "\"maybe\" starts at 1.1 s")
        #expect(updates.last?.settledThrough == 4)
    }

    @Test("A sound description left open at the window's end keeps the settled time before it until a decode closes it")
    func openAnnotationHoldsTheSettledTime() async throws {
        let clock = ManualClock()
        let decoder = FakeDecoder { call, index in
            let hello = word("hello", 0.1, 0.4)
            guard index >= 2 else {
                // "[BLANK" at 0.6 s is still open at the window's end.
                return LiveDecodeResult(hypothesis: call.hypothesis([hello]), language: "en", openAnnotationStart: 0.6)
            }
            let heard = [hello, word("there", 1.1, 1.4)].filter { $0.end <= call.windowEnd }
            return LiveDecodeResult(hypothesis: call.hypothesis(heard), language: "en")
        }
        let session = try await manualSession(decoder, clock: clock)

        await session.play(chunks(from: 0, to: 4), on: clock)
        let final = await session.finish(timeout: .seconds(5))
        let updates = await session.collectedUpdates()

        let whileOpen = updates.prefix { update in !update.rows.contains { $0.settledText.contains("there") || $0.tailText.contains("there") } }
        #expect(whileOpen.contains { $0.rows.contains { $0.settledText == "hello" } }, "hello settles meanwhile")
        #expect(whileOpen.map(\.settledThrough).allSatisfy { $0 <= 0.6 })
        #expect(text(of: latestRows(updates + final)) == "hello there")
    }

    /// "Five", a stray "*" Whisper never closes, then "three is 15." before a pause.
    private static let strayOpenerScript = [
        word("Five", 0.1, 0.4), word("*", 0.6, 0.65), word("three", 0.8, 1.0), word("is", 1.1, 1.3), word("15.", 1.4, 1.7)
    ]

    @Test("A description still open when silence follows was a stray opener: the confirming decode keeps the words after it")
    func strayOpenerBeforeSilenceKeepsTheWordsAfterIt() async throws {
        let clock = ManualClock()
        let decoder = FakeDecoder.describingSounds(Self.strayOpenerScript)
        let session = try await manualSession(decoder, clock: clock)

        await session.play(chunks(from: 0, to: 2) + chunks(from: 2, to: 6, level: Level.silence), on: clock)
        let final = await session.finish(timeout: .seconds(5))
        let updates = await session.collectedUpdates()

        #expect(text(of: latestRows(updates + final)) == "Five three is 15.")
        #expect(updates.flatMap(\.gaps).isEmpty)
    }

    @Test("A description still open at Stop was a stray opener: the final decode keeps the words after it")
    func strayOpenerAtStopKeepsTheWordsAfterIt() async throws {
        let clock = ManualClock()
        let decoder = FakeDecoder.describingSounds(Self.strayOpenerScript)
        let session = try await manualSession(decoder, clock: clock)

        await session.play(chunks(from: 0, to: 2), on: clock)
        let final = await session.finish(timeout: .seconds(5))
        let updates = await session.collectedUpdates()

        #expect(text(of: latestRows(updates + final)) == "Five three is 15.")
    }

    @Test("A held-back word is kept once the window reaches the forced-boundary length")
    func forcedBoundaryKeepsAHeldBackWord() async throws {
        let clock = ManualClock()
        let decoder = FakeDecoder(script: [word("hello", 0.1, 0.4), word("maybe", 0.6, 0.9, probability: 0.2)])
        let session = try await manualSession(decoder, clock: clock)

        // Noise above −45 dBFS: no silence rule ever keeps the word.
        await session.play(chunks(from: 0, to: 1) + chunks(from: 1, to: 32, level: 0.01), on: clock)
        await session.cancel()

        let updates = await session.collectedUpdates()
        let rows = latestRows(updates)
        #expect(text(of: rows) == "hello maybe")
        #expect(rows.first?.isForcedBoundary == true)
        #expect(updates.flatMap(\.gaps).isEmpty)
    }

    @Test("A description still open when the window reaches the forced-boundary length was a stray opener: the words after it are kept")
    func strayOpenerAtTheForcedBoundaryKeepsTheWordsAfterIt() async throws {
        let clock = ManualClock()
        let hello = word("hello", 0.1, 0.4)
        let there = word("there", 1.1, 1.4)
        let decoder = FakeDecoder { call, _ in
            let heard = [hello, there].filter { $0.start >= call.startTime && $0.end <= call.windowEnd }
            // Whisper never closes the "*" at 0.6 s.
            guard call.startTime <= 0.6 else { return LiveDecodeResult(hypothesis: call.hypothesis(heard), language: "en") }
            return LiveDecodeResult(
                hypothesis: call.hypothesis(heard.filter { $0.end <= 0.6 }),
                language: "en",
                openAnnotationStart: 0.6,
                wordsWithoutOpener: heard
            )
        }
        let session = try await manualSession(decoder, clock: clock)

        // Noise above −45 dBFS: no silence rule reads the opener as stray.
        await session.play(chunks(from: 0, to: 2) + chunks(from: 2, to: 32, level: 0.01), on: clock)
        await session.cancel()

        let updates = await session.collectedUpdates()
        let whileOpen = updates.prefix { update in !update.rows.contains { $0.settledText.contains("there") || $0.tailText.contains("there") } }
        #expect(whileOpen.count < updates.count, "a decode of the forced-boundary length keeps the words after the opener")
        #expect((updates.dropFirst(whileOpen.count).first?.transcribedThrough ?? 0) >= LocalAgreementReducer.forcedBoundaryWindow, "the words after the opener wait for the forced boundary")
        #expect(whileOpen.map(\.settledThrough).allSatisfy { $0 <= 0.6 })
        #expect(updates.last.map(\.settledThrough) ?? 0 > 0.6)
        #expect(text(of: latestRows(updates)) == "hello there")
        #expect(updates.flatMap(\.gaps).isEmpty)
    }

    @Test("Finish decodes again to keep an unsure word the last decode left out")
    func finishRecoversAHeldBackUnsureWord() async throws {
        let clock = ManualClock()
        let decoder = FakeDecoder(script: [word("hello", 0.1, 0.4), word("maybe", 1.1, 1.4, probability: 0.2)])
        let session = try await manualSession(decoder, clock: clock)

        await session.play(chunks(from: 0, to: 2), on: clock)
        let final = await session.finish(timeout: .seconds(5))
        let streamed = await session.collectedUpdates()

        #expect(await decoder.calls.map(\.windowEnd) == [1, 2, 2])
        #expect(text(of: latestRows(streamed)) == "hello")
        #expect(text(of: latestRows(streamed + final)) == "hello maybe")
    }
}
