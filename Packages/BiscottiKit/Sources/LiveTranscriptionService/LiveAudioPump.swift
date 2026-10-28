import AudioCapture
import Foundation
import LiveTranscriptModel
import Synchronization

/// Carries the pump's chunks to the engine, one stream per track so a track
/// that waits does not hold up the other, with at most `limit` chunks per
/// track queued or in flight (2 s of audio). A chunk the pipe refuses waits
/// in the pump (`LivePumpCore.retention`) and is offered again.
final class LiveChunkPipe: Sendable {
    static let limit = 8

    let tracks: [LiveTrack]
    private let streams: [LiveTrack: (stream: AsyncStream<LiveAudioChunk>, continuation: AsyncStream<LiveAudioChunk>.Continuation)]
    private let inFlight = Mutex<[LiveTrack: Int]>([:])

    init(tracks: [LiveTrack] = [.mic, .system]) {
        self.tracks = tracks
        streams = Dictionary(uniqueKeysWithValues: tracks.map { track in
            (track, AsyncStream.makeStream(of: LiveAudioChunk.self, bufferingPolicy: .unbounded))
        })
    }

    /// The track's chunks in order. Empty for a track the pipe does not carry.
    func chunks(of track: LiveTrack) -> AsyncStream<LiveAudioChunk> {
        streams[track]?.stream ?? AsyncStream { $0.finish() }
    }

    /// Queues a chunk, or returns false when its track has `limit` chunks
    /// queued or in flight, or the pipe is finished.
    func offer(_ chunk: LiveAudioChunk) -> Bool {
        let track = chunk.track
        guard let continuation = streams[track]?.continuation else { return false }
        let taken = inFlight.withLock { counts in
            guard counts[track, default: 0] < Self.limit else { return false }
            counts[track, default: 0] += 1
            return true
        }
        guard taken else { return false }
        if case .terminated = continuation.yield(chunk) {
            release(track)
            return false
        }
        return true
    }

    /// The engine took or refused a chunk of `track`: its slot is free.
    func release(_ track: LiveTrack) {
        inFlight.withLock { counts in
            counts[track] = max(0, counts[track, default: 0] - 1)
        }
    }

    /// No more chunks; each stream ends once its queued chunks are read.
    func finish() {
        streams.values.forEach { $0.continuation.finish() }
    }
}

/// Drains a recording's live tap on its own queue, every 50 ms, through a
/// `LivePumpCore` into a `LiveChunkPipe`, and reports what happens.
///
/// The spec gives the pump its own thread; a serial `.userInitiated` queue
/// with a timer keeps the one-consumer rule and stops without polling.
final class LiveAudioPump: @unchecked Sendable {
    enum Event {
        /// How far each track's blocks reach.
        case progress([LiveTrack: TimeInterval])
        case gap(LiveGap)
        /// 0…1, at most 12 times a second.
        case level(Float)
        /// Both tracks ended and every chunk is in the pipe.
        case ended
    }

    static let levelInterval: TimeInterval = 1.0 / 12

    let events: AsyncStream<Event>
    private let eventContinuation: AsyncStream<Event>.Continuation
    private let source: any LiveAudioSource
    private let pipe: LiveChunkPipe
    private let interval: Duration

    // Confined to `queue`.
    private let queue = DispatchQueue(label: "net.scosman.biscotti.live-pump", qos: .userInitiated)
    private var core: LivePumpCore?
    private var timer: DispatchSourceTimer?
    private var lastProgress: [LiveTrack: TimeInterval] = [:]
    /// The core's `chunkExtents` at the last tick, kept after it ends.
    private var lastChunkExtents: [LiveTrack: ChunkExtent] = [:]
    private var lastLevelAt: TimeInterval = 0
    private var isStopped = false

    /// - Parameter discardBefore: Audio before this recording time is dropped,
    ///   for a start mid-recording.
    init(source: any LiveAudioSource, pipe: LiveChunkPipe, discardBefore: TimeInterval, interval: Duration = .milliseconds(50)) {
        self.source = source
        self.pipe = pipe
        self.interval = interval
        (events, eventContinuation) = AsyncStream.makeStream(of: Event.self, bufferingPolicy: .unbounded)
        let events = eventContinuation
        // Set before any drain: `start()` hands the core to the queue.
        core = LivePumpCore(discardBefore: discardBefore, sink: { pipe.offer($0) }, onGap: { events.yield(.gap($0)) })
    }

    func start() {
        queue.async { [self] in
            guard !isStopped, timer == nil else { return }
            let timer = DispatchSource.makeTimerSource(queue: queue)
            let nanoseconds = Int(interval.components.seconds * 1_000_000_000 + interval.components.attoseconds / 1_000_000_000)
            timer.schedule(deadline: .now(), repeating: .nanoseconds(nanoseconds), leeway: .milliseconds(5))
            timer.setEventHandler { [weak self] in self?.tick() }
            self.timer = timer
            timer.resume()
        }
    }

    /// How far each track's chunks reach, waiting ones included.
    func chunkExtents() async -> [LiveTrack: ChunkExtent] {
        await withCheckedContinuation { continuation in
            queue.async { [self] in
                continuation.resume(returning: core?.chunkExtents ?? lastChunkExtents)
            }
        }
    }

    /// Stops for good, without flushing. Returns once no drain runs, so
    /// another consumer may take over the tap.
    func stop() async {
        await withCheckedContinuation { continuation in
            queue.async { [self] in
                shutDown()
                continuation.resume()
            }
        }
    }

    private func tick() {
        guard !isStopped, let core else { return }
        // Chunks the engine could not take yet go first, then new audio.
        core.offerWaiting()
        source.micBlocks.drain { core.process($0, on: .mic) }
        source.systemBlocks.drain { core.process($0, on: .system) }

        lastChunkExtents = core.chunkExtents
        let progress = core.capturedThrough
        if progress != lastProgress {
            lastProgress = progress
            eventContinuation.yield(.progress(progress))
        }
        let now = ProcessInfo.processInfo.systemUptime
        if now - lastLevelAt >= Self.levelInterval {
            lastLevelAt = now
            eventContinuation.yield(.level(core.takeLevel()))
        }
        if core.isEnded {
            eventContinuation.yield(.level(0))
            eventContinuation.yield(.ended)
            shutDown()
        }
    }

    private func shutDown() {
        guard !isStopped else { return }
        isStopped = true
        timer?.cancel()
        timer = nil
        core = nil
        pipe.finish()
        eventContinuation.finish()
    }
}
