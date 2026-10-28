import Foundation
import LiveTranscriptModel

/// One track's retained audio.
///
/// `runs[0]` is the decode window. A later run starts after a gap (a
/// discontinuity, a pause or dropped audio) and waits until the session has
/// finished the window: one final decode, then the reducer's `finish()`.
struct TrackAudio {
    struct Run {
        var start: TimeInterval
        var samples: [Float]
        /// The gaps between the previous run and this one, in time order.
        var gapsBefore: [LiveGap]

        var end: TimeInterval {
            start + Double(samples.count) / LiveAudioChunk.sampleRate
        }

        func time(ofSample index: Int) -> TimeInterval {
            start + Double(index) / LiveAudioChunk.sampleRate
        }
    }

    /// Retained audio above this is "falling behind": the oldest undecoded audio is dropped.
    static let retentionLimit = Int(LiveAudioLimits.sessionRetention * LiveAudioChunk.sampleRate)

    let track: LiveTrack
    /// Never empty.
    private(set) var runs: [Run]
    /// Samples at the start of the window that a decode has covered or is
    /// covering. Audio after them is new audio.
    private(set) var decodedCount = 0

    init(track: LiveTrack, start: TimeInterval) {
        self.track = track
        runs = [Run(start: start, samples: [], gapsBefore: [])]
    }

    var window: Run {
        runs[0]
    }

    var undecodedWindowAudio: ArraySlice<Float> {
        runs[0].samples[decodedCount...]
    }

    var hasRunAfterWindow: Bool {
        runs.count > 1
    }

    var end: TimeInterval {
        runs[runs.count - 1].end
    }

    var retainedSampleCount: Int {
        runs.reduce(0) { $0 + $1.samples.count }
    }

    // MARK: - Incoming audio

    mutating func append(_ samples: [Float]) {
        runs[runs.count - 1].samples += samples
    }

    mutating func startRun(at start: TimeInterval, samples: [Float], gap: LiveGap?) {
        runs.append(Run(start: start, samples: samples, gapsBefore: gap.map { [$0] } ?? []))
    }

    /// Drops the oldest undecoded audio until the retained audio fits the limit,
    /// recording each dropped stretch as a `queueOverflow` gap. Audio a decode
    /// covers is kept, so a decode in flight still matches the window.
    /// - Returns: The seconds dropped.
    @discardableResult
    mutating func enforceRetentionLimit() -> TimeInterval {
        var excess = retainedSampleCount - Self.retentionLimit
        guard excess > 0 else { return 0 }
        let requested = excess

        if decodedCount < runs[0].samples.count {
            let dropped = min(excess, runs[0].samples.count - decodedCount)
            let gapStart = runs[0].time(ofSample: decodedCount)
            let overflow = overflowGap(from: gapStart, dropping: runs[0].samples[decodedCount ..< decodedCount + dropped])
            let remainder = Array(runs[0].samples[(decodedCount + dropped)...])
            runs[0].samples.removeSubrange(decodedCount...)
            runs.insert(Run(start: overflow.endTime, samples: remainder, gapsBefore: [overflow]), at: 1)
            excess -= dropped
        }

        var index = 1
        while excess > 0, index < runs.count {
            let dropped = min(excess, runs[index].samples.count)
            if dropped > 0 {
                Self.add(overflowGap(from: runs[index].start, dropping: runs[index].samples.prefix(dropped)), to: &runs[index].gapsBefore)
                runs[index].samples.removeFirst(dropped)
                runs[index].start += Double(dropped) / LiveAudioChunk.sampleRate
                excess -= dropped
            }
            if runs[index].samples.isEmpty, index < runs.count - 1 {
                let gaps = runs.remove(at: index).gapsBefore
                for gap in gaps.reversed() {
                    runs[index].gapsBefore.insert(gap, at: 0)
                }
            } else {
                index += 1
            }
        }
        return Double(requested - excess) / LiveAudioChunk.sampleRate
    }

    // MARK: - Decoding

    /// Marks the whole window, or its first `limit` samples, as decoded and
    /// returns a copy of that audio.
    mutating func beginDecode(limit: Int? = nil) -> (samples: [Float], start: TimeInterval) {
        let count = min(runs[0].samples.count, limit ?? .max)
        decodedCount = max(decodedCount, count)
        return (Array(runs[0].samples.prefix(count)), runs[0].start)
    }

    var windowDuration: TimeInterval {
        Double(runs[0].samples.count) / LiveAudioChunk.sampleRate
    }

    /// Drops window audio before `time`; never audio that no decode has covered.
    mutating func trimWindow(before time: TimeInterval) {
        let offset = Int(((time - runs[0].start) * LiveAudioChunk.sampleRate).rounded())
        let count = min(max(offset, 0), decodedCount)
        runs[0].samples.removeFirst(count)
        runs[0].start += Double(count) / LiveAudioChunk.sampleRate
        decodedCount -= count
    }

    /// Counts the whole window as new audio again, so the next decode, or
    /// the finish, decodes what a catch-up decode left undecided.
    mutating func markWindowUndecoded() {
        decodedCount = 0
    }

    /// Drops the whole window once all of it is resolved; the window restarts at its end.
    mutating func clearWindow() {
        runs[0] = Run(start: runs[0].end, samples: [], gapsBefore: [])
        decodedCount = 0
    }

    /// Replaces the window with the next run.
    /// - Returns: The gaps between the two.
    mutating func advanceToNextRun() -> [LiveGap] {
        runs.removeFirst()
        let gaps = runs[0].gapsBefore
        runs[0].gapsBefore = []
        decodedCount = 0
        return gaps
    }

    // MARK: - Gaps

    /// The gap for dropped samples; silent when every frame of them was.
    private func overflowGap(from start: TimeInterval, dropping samples: ArraySlice<Float>) -> LiveGap {
        LiveGap(
            track: track,
            startTime: start,
            duration: Double(samples.count) / LiveAudioChunk.sampleRate,
            reason: .queueOverflow,
            isSilent: AudioLevel.isSilent(samples)
        )
    }

    /// Extends the last gap when the new one continues it with the same
    /// reason and silence, so a long stall is one gap and a stretch of
    /// speech never hides inside a silent one.
    private static func add(_ gap: LiveGap, to gaps: inout [LiveGap]) {
        let tolerance = 1 / LiveAudioChunk.sampleRate
        if let last = gaps.last, last.reason == gap.reason, last.isSilent == gap.isSilent, abs(last.endTime - gap.startTime) < tolerance {
            gaps[gaps.count - 1].duration = gap.endTime - last.startTime
        } else {
            gaps.append(gap)
        }
    }
}
