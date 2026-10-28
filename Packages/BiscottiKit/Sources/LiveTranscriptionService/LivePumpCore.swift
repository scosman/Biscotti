import Accelerate
import AudioCapture
import Foundation
import LiveTranscription
import LiveTranscriptModel
import os

/// Turns drained blocks into 250 ms chunks of 16 kHz audio on the recording
/// timeline, one track at a time. Each block's start time is the source of
/// truth; a block that starts late is a gap, and one that starts early is
/// trimmed. Confined to the pump's queue.
///
/// Two tracks only. The component spec also sums the tracks for a mixed
/// track; phase 5 chose two-track Whisper (`LiveTranscriptionDefaults.tracks`),
/// so mixing would never run and is not built.
final class LivePumpCore {
    static let chunkSamples = 4000
    /// A block may start this much after the previous one ended and still continue it.
    static let lateTolerance: TimeInterval = 0.02
    /// Overlaps shorter than this are rounding, not repeated audio.
    static let overlapTolerance: TimeInterval = 0.001
    /// The level meter reads the newest 50 ms.
    static let levelSamples = 800
    /// Chunks the sink refuses wait, oldest first, up to this much audio per
    /// track, as 16-bit samples. Older ones are lost. The app hands waiting
    /// audio to the engine only as fast as it transcribes it, so the engine
    /// catches up on it instead of overflowing.
    static let retention: TimeInterval = LiveAudioLimits.pumpBacklog
    /// After a start mid-recording, the tap's queue, full since earlier,
    /// spills overflow this far past the start without a gap.
    static let startOverflowAllowance: TimeInterval = 1

    private static let log = Logger(subsystem: "net.scosman.biscotti", category: "live")

    private final class Track {
        let track: LiveTrack
        var resampler: TrackResampler?
        /// The end of the newest block or gap, nil before the first.
        var capturedThrough: TimeInterval?
        /// The run being chunked: its first sample's time and the samples sent from it.
        var runStart: TimeInterval?
        var runSent = 0
        var pending: [Float] = []
        var nextIsDiscontinuity = false
        /// True once the track has sent or lost audio, so a later run continues something.
        var hasAudio = false
        var isEnded = false
        var recent: [Float] = []
        var hasNewAudio = false
        /// The end of the newest chunk made, nil before the first.
        var chunkedThrough: TimeInterval?
        /// The end of the newest chunk made that was not silent.
        var voicedThrough: TimeInterval?
        /// Chunks the sink has not taken yet, oldest first.
        var waiting = WaitingChunks()
        var waitingDuration: TimeInterval = 0

        init(track: LiveTrack) {
            self.track = track
        }
    }

    private let discardBefore: TimeInterval
    private let sink: (LiveAudioChunk) -> Bool
    private let onGap: (LiveGap) -> Void
    private let tracks: [LiveTrack: Track]

    /// - Parameters:
    ///   - discardBefore: Audio before this time is dropped without a gap: a
    ///     start mid-recording begins there.
    ///   - sink: Takes a chunk, or returns false when it cannot take one now.
    ///     A refused chunk waits and is offered again, before any newer one,
    ///     on the next `offerWaiting()` or chunk. Only audio more than
    ///     `retention` behind is lost, as a `queueOverflow` gap.
    ///   - onGap: Receives each stretch the live path lost.
    init(
        tracks: [LiveTrack] = [.mic, .system],
        discardBefore: TimeInterval = 0,
        sink: @escaping (LiveAudioChunk) -> Bool,
        onGap: @escaping (LiveGap) -> Void
    ) {
        self.discardBefore = discardBefore
        self.sink = sink
        self.onGap = onGap
        self.tracks = Dictionary(uniqueKeysWithValues: tracks.map { ($0, Track(track: $0)) })
    }

    /// True once every track has drained `.end`, been flushed and handed
    /// every chunk to the sink.
    var isEnded: Bool {
        tracks.values.allSatisfy { $0.isEnded && $0.waiting.isEmpty }
    }

    /// Offers each track's waiting chunks, oldest first, until the sink
    /// refuses one. The pump calls it on every tick.
    func offerWaiting() {
        for state in tracks.values {
            offerWaiting(of: state)
        }
    }

    /// How far each track's chunks reach, and its chunks with sound, for
    /// tracks that have made any.
    var chunkExtents: [LiveTrack: ChunkExtent] {
        tracks.compactMapValues { state in
            state.chunkedThrough.map { ChunkExtent(end: $0, voicedEnd: state.voicedThrough) }
        }
    }

    /// The bytes of samples waiting for the sink, across tracks.
    var waitingByteCount: Int {
        tracks.values.reduce(0) { $0 + $1.waiting.sampleCount * MemoryLayout<Int16>.size }
    }

    /// How far each track's blocks reach, for tracks that have had any.
    var capturedThrough: [LiveTrack: TimeInterval] {
        tracks.compactMapValues(\.capturedThrough)
    }

    /// The louder track's level over its newest 50 ms, from −60…0 dBFS to
    /// 0…1. Tracks with no new audio since the last call count as silent.
    func takeLevel() -> Float {
        var loudest: Float = 0
        for state in tracks.values where state.hasNewAudio {
            state.hasNewAudio = false
            loudest = max(loudest, Self.level(ofRMS: vDSP.rootMeanSquare(state.recent)))
        }
        return loudest
    }

    static func level(ofRMS rms: Float) -> Float {
        guard rms > 0 else { return 0 }
        let decibels = 20 * log10(rms)
        return min(1, max(0, (decibels + 60) / 60))
    }

    func process(_ block: LiveAudioBlock, on track: LiveTrack) {
        guard let state = tracks[track], !state.isEnded else { return }
        switch block.kind {
        case let .samples(samples, sampleRate, channelCount):
            receive(samples, sampleRate: sampleRate, channelCount: channelCount, at: block.startTime, into: state)
        case let .gap(duration, kind):
            receiveGap(at: block.startTime, duration: duration, kind: kind, into: state)
        case .end:
            endRun(state)
            state.capturedThrough = max(state.capturedThrough ?? block.startTime, block.startTime)
            state.isEnded = true
        }
    }

    // MARK: - Blocks

    private func receive(
        _ samples: UnsafeBufferPointer<Float>,
        sampleRate: Double,
        channelCount: Int,
        at start: TimeInterval,
        into state: Track
    ) {
        let frames = samples.count / max(channelCount, 1)
        guard frames > 0, sampleRate > 0 else { return }
        let end = start + Double(frames) / sampleRate
        var keepFrom = max(start, discardBefore)
        if let captured = state.capturedThrough, keepFrom < captured - Self.overlapTolerance {
            keepFrom = captured // repeated audio; keep only what is new
        }
        guard keepFrom < end - 0.5 / sampleRate else {
            state.capturedThrough = max(state.capturedThrough ?? end, end)
            return
        }
        let skipFrames = min(frames, Int(((keepFrom - start) * sampleRate).rounded()))
        let keptStart = start + Double(skipFrames) / sampleRate

        if let captured = state.capturedThrough, state.hasAudio, keptStart > captured + Self.lateTolerance {
            recordGap(LiveGap(track: state.track, startTime: captured, duration: keptStart - captured, reason: .captureGap), in: state)
        }
        if let resampler = state.resampler, !resampler.matches(sampleRate: sampleRate, channelCount: channelCount) {
            // The run goes on at the new format: no time jump, only a new converter.
            append(resampler.flush(), to: state)
            state.resampler = nil
        }
        if state.resampler == nil {
            state.resampler = TrackResampler(sampleRate: sampleRate, channelCount: channelCount)
            if state.resampler == nil {
                Self.log.error("No live resampler for \(sampleRate, privacy: .public) Hz, \(channelCount, privacy: .public) channels")
            }
        }
        if state.runStart == nil {
            state.runStart = keptStart
            state.runSent = 0
        }
        if let resampler = state.resampler {
            let kept = UnsafeBufferPointer(rebasing: samples[(skipFrames * channelCount)...])
            append(resampler.convert(kept), to: state)
        }
        state.capturedThrough = end
    }

    private func receiveGap(at start: TimeInterval, duration: TimeInterval, kind: LiveAudioGapKind, into state: Track) {
        let end = start + duration
        var keptStart = max(start, discardBefore, state.capturedThrough ?? start)
        defer { state.capturedThrough = max(state.capturedThrough ?? end, end) }
        guard end > keptStart else { return }
        if !state.hasAudio {
            switch kind {
            case .notStarted:
                // Leading silence before the track's first audio: nothing was missed.
                return
            case .overflow where start < discardBefore:
                // The queue filled before a start mid-recording. Its overflow
                // reaching just past the start is not a gap; beyond that,
                // audio after the start was lost.
                keptStart = max(keptStart, discardBefore + Self.startOverflowAllowance)
                guard end > keptStart else { return }
            case .overflow, .captureGap:
                break
            }
        }
        let reason: LiveGap.Reason = kind == .overflow ? .queueOverflow : .captureGap
        recordGap(LiveGap(track: state.track, startTime: keptStart, duration: end - keptStart, reason: reason), in: state)
    }

    // MARK: - Runs and chunks

    /// Ends the current run, reports the gap, and makes the next chunk
    /// discontinuous.
    private func recordGap(_ gap: LiveGap, in state: Track) {
        endRun(state)
        onGap(gap)
        state.recent = []
        state.hasAudio = true
        state.nextIsDiscontinuity = true
    }

    /// Sends what the run still holds, as a shorter last chunk.
    private func endRun(_ state: Track) {
        if let resampler = state.resampler {
            append(resampler.flush(), to: state)
        }
        if !state.pending.isEmpty {
            send(state.pending, from: state)
            state.pending = []
        }
        state.runStart = nil
        state.runSent = 0
    }

    private func append(_ samples: [Float], to state: Track) {
        guard !samples.isEmpty else { return }
        state.recent = Array((state.recent + samples).suffix(Self.levelSamples))
        state.hasNewAudio = true
        state.pending += samples
        while state.pending.count >= Self.chunkSamples {
            send(Array(state.pending.prefix(Self.chunkSamples)), from: state)
            state.pending.removeFirst(Self.chunkSamples)
        }
    }

    private func send(_ samples: [Float], from state: Track) {
        guard let runStart = state.runStart else { return }
        let start = runStart + Double(state.runSent) / LiveAudioChunk.sampleRate
        state.runSent += samples.count
        let chunk = LiveAudioChunk(track: state.track, startTime: start, samples: samples, isDiscontinuity: state.nextIsDiscontinuity)
        state.nextIsDiscontinuity = false
        state.hasAudio = true
        state.chunkedThrough = chunk.endTime
        let isSilent = AudioLevel.isSilent(samples)
        if !isSilent {
            state.voicedThrough = chunk.endTime
        }
        // Audio the sink takes at once is never converted.
        offerWaiting(of: state)
        if state.waiting.isEmpty, sink(chunk) { return }
        state.waiting.append(WaitingChunk(chunk, isSilent: isSilent))
        state.waitingDuration += chunk.duration
        dropBeyondRetention(in: state)
    }

    private func offerWaiting(of state: Track) {
        while let oldest = state.waiting.first, sink(oldest.chunk) {
            state.waiting.removeFirst()
            state.waitingDuration -= oldest.duration
        }
    }

    /// Drops the oldest waiting audio beyond `retention` as a gap (one per
    /// call; the store joins touching gaps of the same silence); the chunk
    /// after it is discontinuous. The gap is silent when every dropped chunk was.
    private func dropBeyondRetention(in state: Track) {
        var lost: LiveGap?
        while state.waitingDuration > Self.retention + 1e-9, let oldest = state.waiting.first {
            state.waiting.removeFirst()
            state.waitingDuration -= oldest.duration
            let isSilent = oldest.isSilent
            if let gap = lost {
                lost?.duration = oldest.endTime - gap.startTime
                lost?.isSilent = gap.isSilent && isSilent
            } else {
                lost = LiveGap(track: state.track, startTime: oldest.startTime, duration: oldest.duration, reason: .queueOverflow, isSilent: isSilent)
            }
        }
        guard let lost else { return }
        onGap(lost)
        if state.waiting.isEmpty {
            state.nextIsDiscontinuity = true
        } else {
            state.waiting.markFirstDiscontinuous()
        }
    }
}

// MARK: - Waiting chunks

/// How far a track's chunks reach, and the end of the newest one with sound.
struct ChunkExtent: Equatable {
    var end: TimeInterval
    var voicedEnd: TimeInterval?
}

/// A chunk waiting for the sink, kept as 16-bit samples: 15 minutes of a
/// track take about 29 MB instead of 58.
struct WaitingChunk {
    let track: LiveTrack
    let startTime: TimeInterval
    let samples: [Int16]
    var isDiscontinuity: Bool
    let isSilent: Bool

    init(_ chunk: LiveAudioChunk, isSilent: Bool? = nil) {
        track = chunk.track
        startTime = chunk.startTime
        let scaled = vDSP.multiply(Float(Int16.max), vDSP.clip(chunk.samples, to: -1 ... 1))
        samples = vDSP.floatingPointToInteger(scaled, integerType: Int16.self, rounding: .towardNearestInteger)
        isDiscontinuity = chunk.isDiscontinuity
        self.isSilent = isSilent ?? AudioLevel.isSilent(chunk.samples)
    }

    var duration: TimeInterval {
        Double(samples.count) / LiveAudioChunk.sampleRate
    }

    var endTime: TimeInterval {
        startTime + duration
    }

    /// The chunk again, with Float32 samples.
    var chunk: LiveAudioChunk {
        let floats = vDSP.multiply(1 / Float(Int16.max), vDSP.integerToFloatingPoint(samples, floatingPointType: Float.self))
        return LiveAudioChunk(track: track, startTime: startTime, samples: floats, isDiscontinuity: isDiscontinuity)
    }
}

/// Waiting chunks, oldest first. Taking the oldest moves a start index, so
/// a long backlog is not shifted for every chunk handed over.
struct WaitingChunks {
    private var chunks: [WaitingChunk] = []
    private var head = 0
    private(set) var sampleCount = 0

    var isEmpty: Bool {
        head == chunks.count
    }

    var first: WaitingChunk? {
        isEmpty ? nil : chunks[head]
    }

    mutating func append(_ chunk: WaitingChunk) {
        chunks.append(chunk)
        sampleCount += chunk.samples.count
    }

    mutating func removeFirst() {
        guard !isEmpty else { return }
        sampleCount -= chunks[head].samples.count
        head += 1
        if head == chunks.count {
            chunks.removeAll(keepingCapacity: true)
            head = 0
        } else if head >= 256, head * 2 >= chunks.count {
            chunks.removeFirst(head)
            head = 0
        }
    }

    mutating func markFirstDiscontinuous() {
        guard !isEmpty else { return }
        chunks[head].isDiscontinuity = true
    }
}
