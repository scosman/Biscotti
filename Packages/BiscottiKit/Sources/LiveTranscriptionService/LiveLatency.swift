import Foundation
import LiveTranscriptModel
import os

/// In-app live latency, read during a hardware check. The engine experiment
/// (`specs/research/live_transcription/README.md`) measured the session
/// alone; this measures what a real call adds: XPC both ways, the worker's
/// wait for its next decode, merging, the 4 Hz publish and the drawer's
/// drawing.
///
/// Signposts, in the `live.latency` category (Instruments, or
/// `log show --signpost`):
/// - "Live chunk", per chunk: from the engine taking it to the drawer drawing
///   the update that covers it. A "Covered" event marks that update. An
///   update without text ends the interval at once.
/// - "Update to drawn": from the first update with text after a drawing to
///   the next drawing.
///
/// A summary is logged every `windowLength` and when the session ends.
/// Backfill, replayed and paused audio are not measured: they wait by design.
@MainActor
final class LiveLatency {
    static let signposter = OSSignposter(subsystem: "net.scosman.biscotti", category: "live.latency")
    private static let log = Logger(subsystem: "net.scosman.biscotti", category: "live")
    /// A covered chunk the drawer has not drawn within this long is not
    /// measured: the drawer is closed or not on screen.
    static let drawWindow: Duration = .seconds(5)
    /// Chunks waiting for an update, per track: 64 s of 250 ms chunks.
    static let waitingLimit = 256
    /// How often the log gets the figures of the time since the last summary.
    static let windowLength: Duration = .seconds(300)

    struct Figures {
        var chunkToUpdate = LatencyHistogram()
        var chunkToDrawn = LatencyHistogram()
        var updateToDrawn = LatencyHistogram()
        var decode = LatencyHistogram()

        var summary: String {
            [
                "chunk to update \(chunkToUpdate)",
                "chunk to drawn \(chunkToDrawn)",
                "update to drawn \(updateToDrawn)",
                "worker decode \(decode)"
            ].joined(separator: "; ")
        }
    }

    private struct Interval {
        let start: ContinuousClock.Instant
        let id: OSSignpostID
        let state: OSSignpostIntervalState
    }

    private struct TakenChunk {
        let endTime: TimeInterval
        let interval: Interval
    }

    /// A chunk an update with text covered, waiting for the drawer.
    private struct CoveredChunk {
        let interval: Interval
        let coveredAt: ContinuousClock.Instant
    }

    private let now: () -> ContinuousClock.Instant
    private var waiting: [LiveTrack: [TakenChunk]] = [:]
    private var covered: [CoveredChunk] = []
    private var undrawnUpdate: Interval?
    private(set) var session = Figures()
    private(set) var window = Figures()
    private var windowStart: ContinuousClock.Instant
    private var hasEnded = false

    init(now: @escaping () -> ContinuousClock.Instant = { .now }) {
        self.now = now
        windowStart = now()
    }

    /// The engine took a live chunk.
    func chunkTaken(_ chunk: LiveAudioChunk) {
        guard !hasEnded else { return }
        var chunks = waiting[chunk.track, default: []]
        chunks.append(TakenChunk(endTime: chunk.endTime, interval: begin("Live chunk")))
        if chunks.count > Self.waitingLimit {
            Self.signposter.endInterval("Live chunk", chunks.removeFirst().interval.state, "not covered")
        }
        waiting[chunk.track] = chunks
    }

    /// The store applied an update of the running engine.
    func updateApplied(_ update: LiveTrackUpdate) {
        guard !hasEnded else { return }
        let moment = now()
        dropUndrawn(at: moment)
        if let milliseconds = update.decodeMilliseconds {
            record(.milliseconds(milliseconds), in: \.decode)
        }
        let hasText = !update.rows.isEmpty
        var chunks = waiting[update.track] ?? []
        let reached = update.transcribedThrough + LiveTranscriptStore.gapJoinTolerance
        while let chunk = chunks.first, chunk.endTime <= reached {
            chunks.removeFirst()
            record(moment - chunk.interval.start, in: \.chunkToUpdate)
            if hasText {
                Self.signposter.emitEvent("Covered", id: chunk.interval.id)
                covered.append(CoveredChunk(interval: chunk.interval, coveredAt: moment))
            } else {
                Self.signposter.endInterval("Live chunk", chunk.interval.state, "no text")
            }
        }
        waiting[update.track] = chunks
        if hasText, undrawnUpdate == nil {
            undrawnUpdate = begin("Update to drawn")
        }
        logWindowIfDue(at: moment)
    }

    /// The drawer drew the rows the service published.
    func rowsDrawn() {
        guard !hasEnded else { return }
        let moment = now()
        dropUndrawn(at: moment)
        for chunk in covered {
            record(moment - chunk.interval.start, in: \.chunkToDrawn)
            Self.signposter.endInterval("Live chunk", chunk.interval.state)
        }
        covered = []
        if let update = undrawnUpdate {
            record(moment - update.start, in: \.updateToDrawn)
            Self.signposter.endInterval("Update to drawn", update.state)
            undrawnUpdate = nil
        }
    }

    /// A new engine starts from its own audio: the chunks the old one took
    /// and never covered are not measured.
    func generationChanged() {
        for chunk in waiting.values.joined() {
            Self.signposter.endInterval("Live chunk", chunk.interval.state, "engine changed")
        }
        waiting = [:]
    }

    /// The session ended: logs its figures once.
    func end() {
        guard !hasEnded else { return }
        generationChanged()
        dropUndrawn(at: nil)
        hasEnded = true
        let summary = session.summary
        Self.log.notice("Live latency, whole session: \(summary, privacy: .public)")
    }

    // MARK: - Private

    private func begin(_ name: StaticString) -> Interval {
        let id = Self.signposter.makeSignpostID()
        return Interval(start: now(), id: id, state: Self.signposter.beginInterval(name, id: id))
    }

    private func record(_ duration: Duration, in figure: WritableKeyPath<Figures, LatencyHistogram>) {
        let seconds = Double(duration.components.seconds) + Double(duration.components.attoseconds) / 1e18
        session[keyPath: figure].record(seconds)
        window[keyPath: figure].record(seconds)
    }

    /// Ends what waited for the drawer longer than `drawWindow`, or all of
    /// it when `moment` is nil.
    private func dropUndrawn(at moment: ContinuousClock.Instant?) {
        let isStale = { (start: ContinuousClock.Instant) in moment.map { $0 - start > Self.drawWindow } ?? true }
        covered.removeAll { chunk in
            guard isStale(chunk.coveredAt) else { return false }
            Self.signposter.endInterval("Live chunk", chunk.interval.state, "not drawn")
            return true
        }
        if let update = undrawnUpdate, isStale(update.start) {
            Self.signposter.endInterval("Update to drawn", update.state, "not drawn")
            undrawnUpdate = nil
        }
    }

    private func logWindowIfDue(at moment: ContinuousClock.Instant) {
        guard moment - windowStart >= Self.windowLength else { return }
        let minutes = Int(Self.windowLength.components.seconds / 60)
        let summary = window.summary
        Self.log.notice("Live latency, last \(minutes, privacy: .public) min: \(summary, privacy: .public)")
        window = Figures()
        windowStart = moment
    }
}

/// Durations in 10 ms buckets up to 10 s, so a meeting of any length keeps
/// a fixed size; longer ones share the last bucket, and the longest is kept.
struct LatencyHistogram: CustomStringConvertible {
    static let bucketWidth: TimeInterval = 0.01
    static let bucketCount = 1000

    private var buckets: [Int] = []
    /// How many durations were recorded.
    private var total = 0
    private(set) var maximum: TimeInterval = 0

    var count: Int {
        total
    }

    var isEmpty: Bool {
        total == 0
    }

    mutating func record(_ seconds: TimeInterval) {
        if buckets.isEmpty { buckets = Array(repeating: 0, count: Self.bucketCount + 1) }
        let index = min(Int(max(seconds, 0) / Self.bucketWidth), Self.bucketCount)
        buckets[index] += 1
        total += 1
        maximum = max(maximum, seconds)
    }

    /// The upper edge of the bucket holding the given fraction of the
    /// values, never past the longest one; the longest one for the last
    /// bucket; nil when empty.
    func percentile(_ fraction: Double) -> TimeInterval? {
        guard total > 0 else { return nil }
        let rank = max(1, Int((fraction * Double(total)).rounded(.up)))
        var seen = 0
        for (index, bucketCount) in buckets.enumerated() {
            seen += bucketCount
            if seen >= rank, index < Self.bucketCount {
                return min(Double(index + 1) * Self.bucketWidth, maximum)
            }
        }
        return maximum
    }

    var description: String {
        guard let median = percentile(0.5), let p95 = percentile(0.95) else { return "none" }
        return String(format: "p50 %.2f s, p95 %.2f s, max %.2f s (%d)", median, p95, maximum, total)
    }
}
