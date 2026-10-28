import Foundation
import LiveTranscriptModel
import Testing
@testable import LiveTranscription

/// The two tracks together: rows in conversation order, the backlog a start
/// hands over, and gaps that know whether they were silent.
@Suite("WhisperLiveSession conversation")
struct WhisperLiveSessionConversationTests {
    /// Answers the system track (louder audio) from one script and the mic from the other.
    private func decoder(mic: [TimedWord], system: [TimedWord]) -> FakeDecoder {
        FakeDecoder { call, _ in
            let script = call.peak == Level.otherSpeech ? system : mic
            let heard = script.filter { $0.start >= call.startTime && $0.end <= call.windowEnd }
            return LiveDecodeResult(hypothesis: call.hypothesis(heard), language: "en")
        }
    }

    private func play(_ session: WhisperLiveSession, through end: TimeInterval, on clock: ManualClock) async -> [LiveTrackUpdate] {
        await session.play(chunks(.mic, from: 0, to: end), alongside: chunks(.system, from: 0, to: end, level: Level.otherSpeech), on: clock)
        let final = await session.finish(timeout: .seconds(5))
        return await session.collectedUpdates() + final
    }

    @Test("When the other track starts speaking, the row closes and the next words follow the other side's row")
    func otherTrackStartingClosesTheRow() async throws {
        let clock = ManualClock()
        let session = try await manualSession(
            decoder(mic: words("a b c d e f g h", from: 0, length: 0.3), system: [word("yes", 1.6, 1.9)]),
            clock: clock
        )

        let rows = await latestRows(play(session, through: 5, on: clock))

        #expect(rows.map(\.track) == [.mic, .system, .mic])
        #expect(rows.map(\.settledText) == ["a b c d", "yes", "e f g h"])
    }

    @Test("Someone talking over a long turn interleaves with it like a chat")
    func interleavedConversationAlternatesRows() async throws {
        let clock = ManualClock()
        let session = try await manualSession(
            decoder(
                mic: [word("yes", 4.1, 4.4), word("right", 8.1, 8.4)],
                system: words(Array(repeating: "talk", count: 24).joined(separator: " "), from: 0, length: 0.3)
            ),
            clock: clock
        )

        let rows = await latestRows(play(session, through: 13, on: clock))

        #expect(rows.map(\.track) == [.system, .mic, .system, .mic, .system])
        #expect(rows.map(\.startTime) == [0, 4.1, 4.5, 8.1, 8.5])
        #expect(rows.filter { $0.track == .system }.map { $0.settledText.split(separator: " ").count } == [9, 8, 7])
    }

    @Test("The most audio the app hands over at once, with more arriving during slow catch-up decodes, loses nothing")
    func backlogHandedOverAtStartIsNotDropped() async throws {
        let clock = ManualClock()
        let decoder = FakeDecoder()
        let session = try await manualSession(decoder, clock: clock)
        // The app hands over the engine lead and the chunks in transit at once.
        let backlog = LiveAudioLimits.engineLead + LiveAudioLimits.inTransit
        for chunk in chunks(.mic, from: 0, to: backlog, backfill: true) + chunks(.system, from: 0, to: backlog, level: Level.otherSpeech, backfill: true) {
            await session.append(chunk)
        }

        // Each track's first decode takes two seconds while audio keeps coming.
        var arrived = backlog
        for _ in 0 ..< 2 {
            await decoder.hold()
            clock.advance(bySeconds: 1)
            let pass = Task { await session.runScheduledWork() }
            #expect(await eventually { await decoder.heldCount == 1 })
            let next = arrived + 2
            for chunk in chunks(.mic, from: arrived, to: next, backfill: true)
                + chunks(.system, from: arrived, to: next, level: Level.otherSpeech, backfill: true)
            {
                await session.append(chunk)
            }
            arrived = next
            await decoder.release()
            await pass.value
        }
        await session.cancel()

        #expect(await decoder.calls.map(\.peak) == [Level.speech, Level.otherSpeech])
        #expect(await session.collectedUpdates().flatMap(\.gaps).isEmpty)
    }

    @Test("A pause over silence is a silent gap")
    func silentPauseGapIsSilent() async throws {
        let clock = ManualClock()
        let session = try await manualSession(FakeDecoder(script: [word("one", 0.1, 0.4)]), clock: clock, config: config(tracks: [.mixed]))

        await session.play(chunks(.mixed, from: 0, to: 1), on: clock)
        await session.setPaused(true)
        await session.play(chunks(.mixed, from: 1, to: 3, level: Level.silence), on: clock)
        await session.setPaused(false)
        await session.play(chunks(.mixed, from: 3, to: 3.5), on: clock)
        await session.cancel()

        let gaps = await session.collectedUpdates().flatMap(\.gaps)
        #expect(gaps == [LiveGap(track: .mixed, startTime: 1, duration: 2, reason: .paused, isSilent: true)])
    }
}
