import Foundation
import LiveTranscriptModel
import Testing
@testable import LiveTranscription

@Suite("WhisperLiveSession", .timeLimit(.minutes(1)))
struct WhisperLiveSessionTests {
    // MARK: - Scheduling

    @Test("Concurrent passes and a finish run their decodes one at a time")
    func neverRunsTwoDecodesAtOnce() async throws {
        let clock = ManualClock()
        let decoder = FakeDecoder()
        let session = try await manualSession(decoder, clock: clock, config: config(tracks: [.mic, .system]))
        for chunk in chunks(.mic, from: 0, to: 1) + chunks(.system, from: 0, to: 1, level: Level.otherSpeech) {
            await session.append(chunk)
        }
        clock.advance(bySeconds: 1)
        await decoder.hold()

        let firstPass = Task { await session.runScheduledWork() }
        #expect(await eventually { await decoder.calls.count == 1 })
        for chunk in chunks(.mic, from: 1, to: 1.5) {
            await session.append(chunk)
        }
        let secondPass = Task { await session.runScheduledWork() }
        #expect(await eventually { await session.laneWaiterCount == 1 })
        let finishing = Task { await session.finish(timeout: .seconds(60)) }
        #expect(await eventually { await session.laneWaiterCount == 2 })

        await decoder.release()
        await firstPass.value
        await secondPass.value
        _ = await finishing.value

        let calls = await decoder.calls
        #expect(await decoder.maxRunning == 1)
        #expect(calls.map(\.peak) == [Level.speech, Level.speech, Level.otherSpeech])
        #expect(calls.map(\.windowEnd) == [1, 1.5, 1])
    }

    @Test("When both tracks are due, the one decoded longer ago goes first")
    func alternatesTracksWhenBothDue() async throws {
        let clock = ManualClock()
        let decoder = FakeDecoder()
        let session = try await manualSession(decoder, clock: clock, config: config(tracks: [.mic, .system]))
        let system = chunks(.system, from: 0, to: 4.5, level: Level.otherSpeech)
        let mic = chunks(.mic, from: 0.5, to: 4.5)

        // The system track starts half a second before the mic.
        await session.append(system[0])
        clock.advance(bySeconds: 0.5)
        for chunk in mic.prefix(10) + system[1 ..< 12] {
            await session.append(chunk)
        }
        clock.advance(bySeconds: 2.5)
        await session.runScheduledWork()
        clock.advance(bySeconds: 0.25)
        await session.runScheduledWork()

        for chunk in mic.dropFirst(10) + system.dropFirst(12) {
            await session.append(chunk)
        }
        clock.advance(bySeconds: 1.25)
        await session.runScheduledWork()
        await session.runScheduledWork()

        let peaks = await decoder.calls.map(\.peak)
        #expect(peaks == [Level.otherSpeech, Level.speech, Level.otherSpeech, Level.speech])
    }

    @Test("A track decodes after the update interval, and only with half a second of new audio")
    func respectsUpdateInterval() async throws {
        let clock = ManualClock()
        let decoder = FakeDecoder()
        let session = try await manualSession(decoder, clock: clock, config: config(interval: 2))

        await session.play(chunks(from: 0, to: 4), on: clock)
        #expect(await decoder.calls.map(\.windowEnd) == [2, 4])

        clock.advance(bySeconds: 3)
        await session.runScheduledWork()
        await session.play(chunks(from: 4, to: 4.25), on: clock)
        #expect(await decoder.calls.count == 2, "A quarter second of new audio is not enough")

        await session.play(chunks(from: 4.25, to: 4.5), on: clock)
        #expect(await decoder.calls.map(\.windowEnd) == [2, 4, 4.5])
    }

    @Test("The automatic scheduler decodes without being asked")
    func automaticSchedulingDecodesOnItsOwn() async throws {
        let decoder = FakeDecoder()
        let session = WhisperLiveSession(decoder: decoder)
        try await session.start(config(interval: 0.05))
        for chunk in chunks(from: 0, to: 1) {
            await session.append(chunk)
        }
        #expect(await eventually { await decoder.calls.count >= 1 })
        await session.cancel()
    }

    // MARK: - Gaps

    @Test("A discontinuity finishes the audio before it, reports the gap and restarts the window")
    func discontinuityCommitsAndRestartsTrack() async throws {
        let clock = ManualClock()
        let decoder = FakeDecoder(script: [
            word("one", 0.1, 0.4), word("two", 0.6, 0.9), word("three", 1.1, 1.4), word("four", 3.2, 3.5)
        ])
        let session = try await manualSession(decoder, clock: clock)
        var afterGap = chunks(from: 3, to: 4.5)
        afterGap[0].isDiscontinuity = true

        await session.play(chunks(from: 0, to: 1.5) + afterGap, on: clock)
        let final = await session.finish(timeout: .seconds(5))
        let updates = await session.collectedUpdates() + final

        let calls = await decoder.calls
        #expect(calls.map(\.startTime) == [0, 0, 3, 3])
        #expect(calls.map(\.windowEnd) == [1, 1.5, 4.25, 4.5], "The audio before the gap gets one final decode")
        let rows = latestRows(updates)
        #expect(rows.map(\.settledText) == ["one two three", "four"])
        let allClosed = rows.allSatisfy(\.isClosed)
        #expect(allClosed)
        #expect(updates.flatMap(\.gaps) == [LiveGap(track: .mic, startTime: 1.5, duration: 1.5, reason: .captureGap)])
    }

    @Test("Audio piling up past 45 s loses its oldest undecoded part, reported as an overflow gap")
    func fallingBehindDropsOldestAndReportsOverflow() async throws {
        let clock = ManualClock()
        let decoder = FakeDecoder()
        let session = try await manualSession(decoder, clock: clock)

        for chunk in chunks(from: 0, to: 50) {
            await session.append(chunk)
        }
        clock.advance(bySeconds: 1)
        await session.runScheduledWork()
        await session.cancel()

        let calls = await decoder.calls
        #expect(calls.map(\.startTime) == [5])
        #expect(calls.map(\.sampleCount) == [45 * 16000])
        let gaps = await session.collectedUpdates().flatMap(\.gaps)
        #expect(gaps == [LiveGap(track: .mic, startTime: 0, duration: 5, reason: .queueOverflow)])
    }

    @Test("Audio dropped while paused is one gap, and the track resumes with an empty window")
    func pauseEmitsOneGapAndResumesEmpty() async throws {
        let clock = ManualClock()
        let decoder = FakeDecoder(script: [word("one", 0.1, 0.4), word("two", 0.6, 0.9)])
        let session = try await manualSession(decoder, clock: clock)

        await session.play(chunks(from: 0, to: 1), on: clock)
        await session.setPaused(true)
        await session.play(chunks(from: 1, to: 3), on: clock)
        #expect(await decoder.calls.count == 1, "Nothing is decoded while paused")
        await session.setPaused(false)
        await session.play(chunks(from: 3, to: 3.5), on: clock)
        await session.cancel()

        #expect(await decoder.calls.map(\.startTime) == [0, 3])
        let updates = await session.collectedUpdates()
        #expect(updates.flatMap(\.gaps) == [LiveGap(track: .mic, startTime: 1, duration: 2, reason: .paused)])
        #expect(latestRows(updates).map(\.settledText) == ["one two"])
    }
}
