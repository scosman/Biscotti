import Foundation
import LiveTranscriptModel
import Testing
import Transcription
@testable import LiveTranscription

@Suite("WhisperLiveSession finishing", .timeLimit(.minutes(1)))
struct WhisperLiveSessionFinishTests {
    @Test("Finish decodes the remaining audio and returns closed rows instead of streaming them")
    func finishDecodesRemainingAudioAndClosesRows() async throws {
        let clock = ManualClock()
        let decoder = FakeDecoder(script: [word("hello", 0.1, 0.4), word("there", 0.6, 0.9), word("friend", 1.1, 1.4)])
        let session = try await manualSession(decoder, clock: clock)

        await session.play(chunks(from: 0, to: 1), on: clock)
        for chunk in chunks(from: 1, to: 1.5) {
            await session.append(chunk)
        }
        let final = await session.finish(timeout: .seconds(5))
        let streamed = await session.collectedUpdates()

        #expect(await decoder.calls.map(\.windowEnd) == [1, 1.5])
        #expect(final.map(\.track) == [.mic])
        let row = try #require(latestRows(final).first)
        #expect(row.settledText == "hello there friend")
        #expect(row.isClosed && !row.isIncomplete)
        #expect(streamed.flatMap(\.rows).allSatisfy { !$0.isClosed })
        #expect(final.last?.settledThrough == 1.5)

        await session.append(chunks(from: 1.5, to: 1.75)[0])
        #expect(await session.finish(timeout: .seconds(5)).isEmpty)
        #expect(await decoder.calls.count == 2)
    }

    @Test("When finishing runs out of time, the tail is committed and marked incomplete")
    func finishTimeoutMarksTailIncomplete() async throws {
        let clock = ManualClock()
        let decoder = FakeDecoder(script: [word("hello", 0.1, 0.4), word("there", 0.6, 0.9)])
        let session = try await manualSession(decoder, clock: clock)
        await session.play(chunks(from: 0, to: 1), on: clock)
        await decoder.hold()
        for chunk in chunks(from: 1, to: 1.5) {
            await session.append(chunk)
        }

        let finishing = Task { await session.finish(timeout: .seconds(10)) }
        #expect(await eventually { await decoder.heldCount == 1 && clock.sleeperCount == 1 })
        clock.advance(bySeconds: 10)
        let final = await finishing.value
        await decoder.release()

        let row = try #require(latestRows(final).first)
        #expect(row.settledText == "hello there")
        #expect(row.isClosed && row.isIncomplete)
        #expect(await decoder.calls.count == 2)
    }

    @Test("Cancel ends the stream and answers a finish that is waiting")
    func cancelEndsTheStreamAndAnswersAWaitingFinish() async throws {
        let clock = ManualClock()
        let decoder = FakeDecoder()
        let session = try await manualSession(decoder, clock: clock)
        for chunk in chunks(from: 0, to: 1) {
            await session.append(chunk)
        }
        await decoder.hold()
        let finishing = Task { await session.finish(timeout: .seconds(60)) }
        #expect(await eventually { await decoder.heldCount == 1 })

        await session.cancel()
        #expect(await finishing.value.isEmpty)
        _ = await session.collectedUpdates()
        await decoder.release()
    }

    @Test("A decode error ends the session")
    func decodeFailureEndsTheSession() async throws {
        let clock = ManualClock()
        let decoder = FakeDecoder { _, _ in throw FakeDecoderError() }
        let session = try await manualSession(decoder, clock: clock)

        await session.play(chunks(from: 0, to: 1), on: clock)
        #expect(await session.collectedUpdates().isEmpty, "The stream ends")

        await session.play(chunks(from: 1, to: 3), on: clock)
        #expect(await decoder.calls.count == 1)
        #expect(await session.finish(timeout: .seconds(5)).isEmpty)
    }

    @Test("Finishing while paused reports the paused audio as one gap per track")
    func finishWhilePausedReportsTheGap() async throws {
        let clock = ManualClock()
        let decoder = FakeDecoder(script: [word("one", 0.1, 0.4), word("two", 0.6, 0.9)])
        let session = try await manualSession(decoder, clock: clock)
        await session.play(chunks(.mic, from: 0, to: 1), on: clock)
        await session.setPaused(true)
        await session.play(chunks(.mic, from: 1, to: 2), alongside: chunks(.system, from: 1, to: 2, level: Level.otherSpeech), on: clock)
        let final = await session.finish(timeout: .seconds(5))

        #expect(final.flatMap(\.gaps) == [
            LiveGap(track: .mic, startTime: 1, duration: 1, reason: .paused),
            LiveGap(track: .system, startTime: 1, duration: 1, reason: .paused)
        ])
        #expect(latestRows(final).map(\.settledText) == ["one two"])
        #expect(await decoder.calls.count == 1)
    }

    @Test("A decode error while finishing returns the rows so far, marked incomplete")
    func decodeFailureWhileFinishingMarksTailIncomplete() async throws {
        let clock = ManualClock()
        let decoder = FakeDecoder { call, index in
            guard index == 0 else { throw FakeDecoderError() }
            return LiveDecodeResult(hypothesis: call.hypothesis([word("hello", 0.1, 0.4), word("there", 0.6, 0.9)]), language: "en")
        }
        let session = try await manualSession(decoder, clock: clock)
        await session.play(chunks(from: 0, to: 1), on: clock)
        for chunk in chunks(from: 1, to: 1.5) {
            await session.append(chunk)
        }
        let final = await session.finish(timeout: .seconds(5))

        let row = try #require(latestRows(final).first)
        #expect(row.settledText == "hello there")
        #expect(row.isClosed && row.isIncomplete)
    }

    @Test("A timeout marks only the track still finishing as incomplete")
    func timeoutLeavesAFinishedTrackComplete() async throws {
        let clock = ManualClock()
        let decoder = FakeDecoder { call, _ in
            let spoken = call.peak == Level.otherSpeech ? [word("hi", 0.2, 0.4), word("there", 0.6, 0.9)] : [word("one", 0.1, 0.4), word("two", 0.6, 0.9)]
            return LiveDecodeResult(hypothesis: call.hypothesis(spoken.filter { $0.end <= call.windowEnd }), language: "en")
        }
        let session = try await manualSession(decoder, clock: clock)
        await session.play(chunks(.mic, from: 0, to: 1), alongside: chunks(.system, from: 0, to: 1, level: Level.otherSpeech), on: clock)
        await session.runScheduledWork()
        for chunk in chunks(.system, from: 1, to: 1.5, level: Level.otherSpeech) {
            await session.append(chunk)
        }

        // The mic finishes without decoding; the system track's final decode never returns.
        await decoder.hold()
        let finishing = Task { await session.finish(timeout: .seconds(10)) }
        #expect(await eventually { await decoder.heldCount == 1 && clock.sleeperCount == 1 })
        clock.advance(bySeconds: 10)
        let final = await finishing.value
        await decoder.release()

        // The system track starts speaking at 0.2 s, inside the mic's row, so
        // the mic's "two" starts a row after it.
        let rows = latestRows(final)
        #expect(rows.map(\.track) == [.mic, .system, .mic])
        #expect(rows.map(\.settledText) == ["one", "hi there", "two"])
        #expect(rows.map(\.isIncomplete) == [false, true, false])
        #expect(await decoder.calls.map(\.peak) == [Level.speech, Level.otherSpeech, Level.otherSpeech])
    }
}
