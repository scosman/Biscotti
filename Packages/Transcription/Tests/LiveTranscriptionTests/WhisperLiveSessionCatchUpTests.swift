import Foundation
import LiveTranscriptModel
import Testing
@testable import LiveTranscription

/// Backfill: audio kept while no engine ran is decoded once in long windows,
/// settled in conversation order, and then the tracks stream.
@Suite("WhisperLiveSession catch-up")
struct WhisperLiveSessionCatchUpTests {
    private static let window = Int(LiveAudioLimits.catchUpWindow * LiveAudioChunk.sampleRate)

    /// Answers the system track (louder audio) from one script and the mic from the other.
    private func decoder(mic: [TimedWord], system: [TimedWord] = []) -> FakeDecoder {
        FakeDecoder { call, _ in
            let script = call.peak == Level.otherSpeech ? system : mic
            let heard = script.filter { $0.start >= call.startTime && $0.end <= call.windowEnd }
            return LiveDecodeResult(hypothesis: call.hypothesis(heard), language: "en")
        }
    }

    private func append(_ chunks: [LiveAudioChunk], to session: WhisperLiveSession) async {
        for chunk in chunks {
            await session.append(chunk)
        }
    }

    /// Advances the clock by one update interval and runs a pass.
    private func pass(_ session: WhisperLiveSession, on clock: ManualClock) async {
        clock.advance(bySeconds: 1)
        await session.runScheduledWork()
    }

    private func finishAndCollect(_ session: WhisperLiveSession) async -> [LiveTrackUpdate] {
        let final = await session.finish(timeout: .seconds(5))
        return await session.collectedUpdates() + final
    }

    @Test("Backfill is decoded in 30 s windows; a word near a window's end waits for the next one, and times stay exact")
    func backfillIsDecodedInWindows() async throws {
        let clock = ManualClock()
        let script = [word("intro", 5, 5.3), word("edge", 28.5, 28.9), word("held", 29.2, 29.6), word("later", 50, 50.4)]
        let decoder = decoder(mic: script)
        let session = try await manualSession(decoder, clock: clock, config: config(tracks: [.mixed]))

        await append(chunks(.mixed, from: 0, to: 40, backfill: true), to: session)
        await pass(session, on: clock)
        await append(chunks(.mixed, from: 40, to: 65, backfill: true), to: session)
        await pass(session, on: clock)
        let calls = await decoder.calls
        let updates = await finishAndCollect(session)

        // "held" ends in the first window's last second, so the next window starts there.
        #expect(calls.prefix(2).map(\.sampleCount) == [Self.window, Self.window])
        #expect(calls.prefix(2).map(\.startTime) == [0, 29])
        let rows = latestRows(updates)
        #expect(rows.map(\.settledText) == ["intro", "edge held", "later"])
        #expect(rows.map(\.startTime) == [5, 28.5, 50])
        #expect(updates.flatMap(\.gaps).isEmpty)
    }

    @Test("A sound description left open in a catch-up window is decoded again from its start, so nothing after it is lost")
    func openAnnotationInCatchUpIsDecodedAgain() async throws {
        let clock = ManualClock()
        let decoder = FakeDecoder { call, index in
            let heard = [word("intro", 5, 5.3), word("later", 20, 20.4)].filter { $0.start >= call.startTime && $0.end <= call.windowEnd }
            guard index > 0 else {
                // The first decode ends inside "[BLANK" at 12 s and keeps nothing after it.
                return LiveDecodeResult(hypothesis: call.hypothesis(heard.filter { $0.end <= 12 }), language: "en", openAnnotationStart: 12)
            }
            return LiveDecodeResult(hypothesis: call.hypothesis(heard), language: "en")
        }
        let session = try await manualSession(decoder, clock: clock, config: config(tracks: [.mixed]))

        await append(chunks(.mixed, from: 0, to: 40, backfill: true), to: session)
        await pass(session, on: clock)
        // Within the 45 s the session keeps from the window's start at 12 s.
        await append(chunks(.mixed, from: 40, to: 50, backfill: true), to: session)
        await pass(session, on: clock)
        let calls = await decoder.calls
        let updates = await finishAndCollect(session)

        #expect(calls.prefix(2).map(\.startTime) == [0, 12])
        #expect(latestRows(updates).map(\.settledText) == ["intro", "later"])
        #expect(updates.flatMap(\.gaps).isEmpty)
    }

    @Test("Before a gap, a description still open was a stray opener: the catch-up decode keeps the words after it")
    func strayOpenerBeforeAGapKeepsTheWordsAfterIt() async throws {
        let clock = ManualClock()
        let script = [
            word("Five", 8.1, 8.4), word("*", 8.6, 8.65), word("three", 8.8, 9.0), word("is", 9.1, 9.3), word("15.", 9.4, 9.7),
            word("after", 22, 22.4)
        ]
        let decoder = FakeDecoder.describingSounds(script)
        let session = try await manualSession(decoder, clock: clock, config: config(tracks: [.mixed]))

        await append(chunks(.mixed, from: 0, to: 10, backfill: true), to: session)
        var resumed = chunks(.mixed, from: 20, to: 50, backfill: true)
        resumed[0].isDiscontinuity = true
        await append(resumed, to: session)
        await pass(session, on: clock)
        await pass(session, on: clock)
        let updates = await finishAndCollect(session)

        #expect(latestRows(updates).map(\.settledText) == ["Five three is 15.", "after"])
    }

    @Test("Two tracks catching up settle in conversation order, as streaming does")
    func tracksSettleInConversationOrder() async throws {
        let clock = ManualClock()
        let decoder = decoder(mic: words("a b c d e f g h", from: 0, length: 0.3), system: [word("yes", 1.6, 1.9)])
        let session = try await manualSession(decoder, clock: clock)

        await append(chunks(.mic, from: 0, to: 40, backfill: true), to: session)
        await append(chunks(.system, from: 0, to: 40, level: Level.otherSpeech, backfill: true), to: session)
        await pass(session, on: clock)
        await pass(session, on: clock)
        let updates = await finishAndCollect(session)

        #expect(await decoder.calls.prefix(2).map(\.peak) == [Level.speech, Level.otherSpeech])
        // The mic's words wait until the system track has decoded as far.
        let firstRows = try #require(updates.firstIndex { !$0.rows.isEmpty })
        let firstSystem = try #require(updates.firstIndex { $0.track == .system })
        #expect(firstSystem < firstRows)
        let rows = latestRows(updates)
        #expect(rows.map(\.track) == [.mic, .system, .mic])
        #expect(rows.map(\.settledText) == ["a b c d", "yes", "e f g h"])
    }

    @Test("A silent catch-up window is not decoded, and the track's transcribed time still moves")
    func silentWindowIsSkipped() async throws {
        let clock = ManualClock()
        let decoder = FakeDecoder()
        let session = try await manualSession(decoder, clock: clock, config: config(tracks: [.mixed]))

        await append(chunks(.mixed, from: 0, to: 40, level: Level.silence, backfill: true), to: session)
        await pass(session, on: clock)
        await session.cancel()

        #expect(await decoder.calls.isEmpty)
        let through = await session.collectedUpdates().last?.transcribedThrough ?? 0
        #expect(abs(through - 29) < 0.001)
    }

    @Test("No streaming decode runs while a track catches up; at the live edge it decodes the rest once, then both tracks stream")
    func handsOverToStreamingAtTheLiveEdge() async throws {
        let clock = ManualClock()
        let decoder = decoder(mic: [word("one", 2, 2.4), word("two", 19.5, 19.9)], system: words("hi there", from: 21))
        let session = try await manualSession(decoder, clock: clock)

        // The mic catches up on 20 s while the system track's audio is live.
        await append(chunks(.mic, from: 0, to: 16, backfill: true), to: session)
        await session.play(
            chunks(.mic, from: 16, to: 20, backfill: true),
            alongside: chunks(.system, from: 16, to: 20, level: Level.otherSpeech),
            on: clock
        )
        #expect(await decoder.calls.isEmpty)

        // Live mic audio: the rest of the backfill is decoded once, then streaming starts.
        await session.play(chunks(.mic, from: 20, to: 24), alongside: chunks(.system, from: 20, to: 24, level: Level.otherSpeech), on: clock)
        let calls = await decoder.calls
        let updates = await finishAndCollect(session)

        let first = try #require(calls.first)
        #expect(first.peak == Level.speech)
        #expect(abs(first.startTime) < 0.001)
        #expect(first.sampleCount == Int(20.25 * LiveAudioChunk.sampleRate))
        // Streaming decodes follow: "two" ends in the last second, so the mic streams from there.
        #expect(calls.dropFirst().contains { $0.peak == Level.otherSpeech })
        #expect(calls.dropFirst().contains { $0.peak == Level.speech && abs($0.startTime - 19.25) < 0.001 })
        let rows = latestRows(updates)
        #expect(rows.map(\.settledText) == ["one", "two", "hi there"])
    }

    @Test("A track whose audio stops while it catches up decodes what it holds, its last words too, and lets the other track stream")
    func stalledTrackEndsCatchUp() async throws {
        let clock = ManualClock()
        let decoder = decoder(mic: [word("one", 2, 2.4), word("last", 9.4, 9.9)], system: words("hi there", from: 0.5))
        let session = try await manualSession(decoder, clock: clock)

        await append(chunks(.mic, from: 0, to: 10, backfill: true), to: session)
        await session.play(chunks(.system, from: 0, to: 4, level: Level.otherSpeech), on: clock)
        let calls = await decoder.calls
        let updates = await finishAndCollect(session)

        #expect(calls.first?.peak == Level.speech)
        #expect(calls.contains { $0.peak == Level.otherSpeech })
        // Nothing follows the stalled track's audio, so its last word is not held back.
        #expect(calls.count(where: { $0.peak == Level.speech }) == 1)
        #expect(latestRows(updates).map(\.settledText) == ["hi there", "one", "last"])
    }

    @Test("While the app holds audio back for a slow catch-up decode, the track does not count as stalled")
    func slowDecodeIsNotAStall() async throws {
        let clock = ManualClock()
        let script = [word("held", 29.2, 29.6)]
        // The first window's decode takes 2.5 s on the clock.
        let decoder = FakeDecoder { call, index in
            if index == 0 { clock.advance(bySeconds: 2.5) }
            let heard = script.filter { $0.start >= call.startTime && $0.end <= call.windowEnd }
            return LiveDecodeResult(hypothesis: call.hypothesis(heard), language: "en")
        }
        let session = try await manualSession(decoder, clock: clock, config: config(tracks: [.mixed]))

        await append(chunks(.mixed, from: 0, to: 37, backfill: true), to: session)
        await pass(session, on: clock)
        // The app's next chunks come once it has the decode's update.
        clock.advance(bySeconds: 0.1)
        await session.runScheduledWork()
        #expect(await decoder.calls.count == 1, "no short decode keeping every word")

        await append(chunks(.mixed, from: 37, to: 60, backfill: true), to: session)
        await pass(session, on: clock)
        let calls = await decoder.calls
        await session.cancel()
        #expect(calls.map(\.startTime) == [0, 29])
        #expect(calls.map(\.sampleCount) == [Self.window, Self.window])
    }

    @Test("A track that falls behind while the other catches up still settles in conversation order")
    func trackJoiningCatchUpKeepsConversationOrder() async throws {
        let clock = ManualClock()
        let decoder = decoder(mic: words("a b c d", from: 3) + words("e f", from: 6), system: [word("yes", 5, 5.3)])
        let session = try await manualSession(decoder, clock: clock)

        // The system track has streamed audio it has not decoded yet when the mic's backlog arrives.
        await append(chunks(.system, from: 0, to: 5.5, level: Level.otherSpeech), to: session)
        await append(chunks(.mic, from: 0, to: 40, backfill: true), to: session)
        await pass(session, on: clock)
        // Then the system track falls behind and joins catch-up.
        await append(chunks(.system, from: 5.5, to: 40, level: Level.otherSpeech, backfill: true), to: session)
        await pass(session, on: clock)
        let updates = await finishAndCollect(session)

        let rows = latestRows(updates)
        #expect(rows.map(\.track) == [.mic, .system, .mic])
        #expect(rows.map(\.settledText) == ["a b c d", "yes", "e f"])
    }

    @Test("A word held back at the live edge is decoded at the finish, even when no more audio came")
    func heldBackWordIsDecodedAtTheFinish() async throws {
        let clock = ManualClock()
        let decoder = decoder(mic: [word("start", 1, 1.4), word("end", 9.5, 9.9)])
        let session = try await manualSession(decoder, clock: clock, config: config(tracks: [.mixed]))

        await append(chunks(.mixed, from: 0, to: 10, backfill: true), to: session)
        await append(chunks(.mixed, from: 10, to: 10.25), to: session)
        await pass(session, on: clock)
        let updates = await finishAndCollect(session)

        let calls = await decoder.calls
        #expect(calls.count == 2, "the live-edge decode, then the finish's")
        #expect(abs((calls.last?.startTime ?? 0) - 9.25) < 0.001)
        #expect(latestRows(updates).map(\.settledText) == ["start", "end"])
    }

    @Test("The finish settles the words catch-up kept, before its final decodes")
    func finishSettlesKeptWords() async throws {
        let clock = ManualClock()
        let decoder = decoder(mic: [word("early", 3, 3.4), word("late", 35, 35.4)])
        let session = try await manualSession(decoder, clock: clock)

        // The system track has sent nothing yet, so the mic's words wait.
        await append(chunks(.mic, from: 0, to: 40, backfill: true), to: session)
        await pass(session, on: clock)
        let updates = await finishAndCollect(session)

        #expect(await decoder.calls.count == 2)
        #expect(latestRows(updates).map(\.settledText) == ["early", "late"])
        #expect(latestRows(updates).allSatisfy { !$0.isIncomplete })
    }

    @Test("Backfill with a gap: the words before it are all kept, the gap is reported and catch-up goes on after it")
    func gapInBackfill() async throws {
        let clock = ManualClock()
        let decoder = decoder(mic: [word("before", 9.6, 10), word("after", 22, 22.4)])
        let session = try await manualSession(decoder, clock: clock, config: config(tracks: [.mixed]))

        await append(chunks(.mixed, from: 0, to: 10, backfill: true), to: session)
        var resumed = chunks(.mixed, from: 20, to: 50, backfill: true)
        resumed[0].isDiscontinuity = true
        await append(resumed, to: session)
        await pass(session, on: clock)
        await pass(session, on: clock)
        let calls = await decoder.calls
        let updates = await finishAndCollect(session)

        #expect(calls.prefix(2).map(\.startTime) == [0, 20])
        #expect(calls.prefix(2).map(\.sampleCount) == [Int(10 * LiveAudioChunk.sampleRate), Self.window])
        #expect(updates.flatMap(\.gaps) == [LiveGap(track: .mixed, startTime: 10, duration: 10, reason: .captureGap)])
        #expect(latestRows(updates).map(\.settledText) == ["before", "after"])
    }
}
