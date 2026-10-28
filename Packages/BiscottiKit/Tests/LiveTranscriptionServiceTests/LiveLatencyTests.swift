import Foundation
import LiveTranscriptModel
import Testing
@testable import LiveTranscriptionService

/// A clock the test moves by hand.
@MainActor
private final class ManualClock {
    private(set) var now = ContinuousClock.now

    func advance(_ duration: Duration) {
        now += duration
    }
}

@MainActor
private func makeLatency() -> (LiveLatency, ManualClock) {
    let clock = ManualClock()
    return (LiveLatency { clock.now }, clock)
}

private func isClose(_ value: TimeInterval, _ expected: TimeInterval) -> Bool {
    abs(value - expected) < 1e-9
}

private func chunk(_ track: LiveTrack = .mic, from start: TimeInterval) -> LiveAudioChunk {
    LiveAudioChunk(track: track, startTime: start, samples: [Float](repeating: 0, count: 4000))
}

private func update(
    _ track: LiveTrack = .mic,
    through time: TimeInterval,
    withText: Bool = true,
    decodeMilliseconds: Double? = nil
) -> LiveTrackUpdate {
    let row = LiveRow(track: track, startTime: 0, endTime: time, settledText: "Hello", tailText: "")
    return LiveTrackUpdate(
        sessionID: UUID(),
        generation: 1,
        track: track,
        revision: 1,
        rows: withText ? [row] : [],
        gaps: [],
        transcribedThrough: time,
        settledThrough: time,
        decodeMilliseconds: decodeMilliseconds
    )
}

@Suite("Live latency")
@MainActor
struct LiveLatencyTests {
    @Test("A chunk counts from when the engine took it to the update that covers its end")
    func chunkToUpdateCountsFromTakenToTheCoveringUpdate() {
        let (latency, clock) = makeLatency()
        latency.chunkTaken(chunk(from: 0)) // ends at 0.25 s
        clock.advance(.milliseconds(250))
        latency.chunkTaken(chunk(from: 0.25)) // ends at 0.5 s
        clock.advance(.milliseconds(500))

        latency.updateApplied(update(through: 0.3))
        #expect(latency.session.chunkToUpdate.count == 1, "the second chunk is not covered yet")
        #expect(isClose(latency.session.chunkToUpdate.maximum, 0.75))

        clock.advance(.milliseconds(250))
        latency.updateApplied(update(.system, through: 1))
        #expect(latency.session.chunkToUpdate.count == 1, "another track's update covers nothing here")
        latency.updateApplied(update(through: 0.5))
        #expect(latency.session.chunkToUpdate.count == 2)
        #expect(isClose(latency.session.chunkToUpdate.maximum, 0.75), "the second chunk waited 0.75 s too")
    }

    @Test("A covered chunk counts to the drawer's next drawing, and so does the update")
    func chunkToDrawnWaitsForTheDrawing() {
        let (latency, clock) = makeLatency()
        latency.chunkTaken(chunk(from: 0))
        clock.advance(.milliseconds(600))
        latency.updateApplied(update(through: 0.25, decodeMilliseconds: 180))
        #expect(latency.session.chunkToDrawn.isEmpty)

        clock.advance(.milliseconds(40))
        latency.rowsDrawn()
        #expect(latency.session.chunkToDrawn.count == 1)
        #expect(isClose(latency.session.chunkToDrawn.maximum, 0.64))
        #expect(latency.session.updateToDrawn.count == 1)
        #expect(isClose(latency.session.updateToDrawn.maximum, 0.04))
        #expect(isClose(latency.session.decode.maximum, 0.18))

        latency.rowsDrawn()
        #expect(latency.session.updateToDrawn.count == 1, "a drawing with nothing new records nothing")
    }

    @Test("An update without text ends its chunks at the update; nothing waits for a drawing")
    func updateWithoutRowsEndsTheChunkAtTheUpdate() {
        let (latency, clock) = makeLatency()
        latency.chunkTaken(chunk(from: 0))
        clock.advance(.milliseconds(500))
        latency.updateApplied(update(through: 0.25, withText: false))
        latency.rowsDrawn()

        #expect(latency.session.chunkToUpdate.count == 1)
        #expect(latency.session.chunkToDrawn.isEmpty)
        #expect(latency.session.updateToDrawn.isEmpty)
    }

    @Test("Chunks and updates the drawer does not draw within five seconds are not measured")
    func undrawnChunksExpire() {
        let (latency, clock) = makeLatency()
        latency.chunkTaken(chunk(from: 0))
        latency.updateApplied(update(through: 0.25))
        clock.advance(LiveLatency.drawWindow + .milliseconds(1))
        latency.rowsDrawn()

        #expect(latency.session.chunkToUpdate.count == 1)
        #expect(latency.session.chunkToDrawn.isEmpty)
        #expect(latency.session.updateToDrawn.isEmpty)
    }

    @Test("A new engine generation drops the chunks the old one never covered")
    func generationChangeDropsWaitingChunks() {
        let (latency, _) = makeLatency()
        latency.chunkTaken(chunk(from: 0))
        latency.generationChanged()
        latency.updateApplied(update(through: 1))

        #expect(latency.session.chunkToUpdate.isEmpty)
    }

    @Test("At most 256 chunks wait per track; the oldest go first")
    func waitingChunksAreBounded() {
        let (latency, _) = makeLatency()
        for index in 0 ..< LiveLatency.waitingLimit + 10 {
            latency.chunkTaken(chunk(from: Double(index) * 0.25))
        }
        latency.updateApplied(update(through: 1000))

        #expect(latency.session.chunkToUpdate.count == LiveLatency.waitingLimit)
    }

    @Test("The summary names each figure with its percentiles and count; the window starts over after each summary")
    func summaryReportsPercentiles() {
        let (latency, clock) = makeLatency()
        latency.chunkTaken(chunk(from: 0))
        clock.advance(.milliseconds(500))
        latency.updateApplied(update(through: 0.25))
        #expect(latency.session.summary.hasPrefix("chunk to update p50 0.50 s, p95 0.50 s, max 0.50 s (1); chunk to drawn none"))
        #expect(latency.window.chunkToUpdate.count == 1)

        clock.advance(LiveLatency.windowLength)
        latency.updateApplied(update(.system, through: 1))
        #expect(latency.window.chunkToUpdate.isEmpty, "a summary was logged and the window began again")
        #expect(latency.session.chunkToUpdate.count == 1)

        latency.end()
        latency.chunkTaken(chunk(from: 1))
        latency.updateApplied(update(through: 2))
        #expect(latency.session.chunkToUpdate.count == 1, "nothing is measured after the end")
    }

    @Test("Percentiles are bucket upper edges, never past the longest value")
    func histogramPercentiles() {
        var histogram = LatencyHistogram()
        #expect(histogram.percentile(0.5) == nil)
        #expect(histogram.description == "none")
        for value in [0.104, 0.205, 0.315, 0.425, 12.0] {
            histogram.record(value)
        }

        #expect(isClose(histogram.percentile(0.5) ?? 0, 0.32))
        #expect(isClose(histogram.percentile(0.2) ?? 0, 0.11))
        #expect(histogram.percentile(0.95) == 12.0, "beyond 10 s the longest value stands in")
        #expect(histogram.maximum == 12.0)
        #expect(histogram.count == 5)
    }
}
