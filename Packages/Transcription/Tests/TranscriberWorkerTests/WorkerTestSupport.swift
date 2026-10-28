import Foundation
import LiveTranscription
import LiveTranscriptModel
import Synchronization
import Testing
import Transcription
@testable import TranscriberWorker

// MARK: - Event log

/// What the fakes did, in order, across all of them.
final class EventLog: Sendable {
    private let events = Mutex<[String]>([])

    var all: [String] {
        events.withLock { $0 }
    }

    func add(_ event: String) {
        events.withLock { $0.append(event) }
    }
}

/// A value shared with escaping closures (a `Mutex` itself cannot be captured).
final class Locked<Value: Sendable>: Sendable {
    private let storage: Mutex<Value>

    init(_ value: Value) {
        storage = Mutex(value)
    }

    var value: Value {
        storage.withLock { $0 }
    }

    @discardableResult
    func update<Result: Sendable>(_ body: @Sendable (inout Value) -> Result) -> Result {
        storage.withLock { body(&$0) }
    }
}

/// Waits until `condition` holds, failing the test after two seconds.
func until(_ condition: () async -> Bool, sourceLocation: SourceLocation = #_sourceLocation) async throws {
    for _ in 0 ..< 400 {
        if await condition() { return }
        try await Task.sleep(for: .milliseconds(5))
    }
    Issue.record("Timed out waiting for a condition", sourceLocation: sourceLocation)
}

// MARK: - Final-pass engine

/// A final-pass engine whose pass runs until the test releases it or its
/// task is cancelled.
actor FakeHostedEngine: HostedTranscriptionEngine {
    nonisolated let whisperModel: String
    private let log: EventLog
    private let sharedDecoder: any LiveDecoder
    private(set) var isRunningPass = false
    private var isReleased = false
    private var modelLoadObserver: (@Sendable (Bool) -> Void)?

    func observeModelLoads(_ observer: (@Sendable (Bool) -> Void)?) async {
        modelLoadObserver = observer
    }

    init(whisperModel: String = "final-model", log: EventLog, sharedDecoder: any LiveDecoder = HoldingDecoder()) {
        self.whisperModel = whisperModel
        self.log = log
        self.sharedDecoder = sharedDecoder
    }

    func sharedLiveDecoder() async throws -> any LiveDecoder {
        log.add("share final model")
        return sharedDecoder
    }

    func processAudio(micPath _: String, systemPath _: String, customVocabulary _: [String]) async throws -> TranscriptResult {
        log.add("pass")
        // Loads its model first, as the real engine does.
        modelLoadObserver?(true)
        modelLoadObserver?(false)
        isRunningPass = true
        defer { isRunningPass = false }
        do {
            while !isReleased {
                try await Task.sleep(for: .milliseconds(2))
            }
        } catch {
            throw TranscriptionError.cancelled
        }
        return TranscriptResult(transcriptionMethodId: "v1", language: "en", speakerCount: 0, segments: [], processingDuration: 0)
    }

    func releasePass() {
        isReleased = true
    }

    func ensureModelsDownloaded(status _: @escaping @Sendable (String) -> Void) async throws {}

    func unloadModels() async {
        log.add("unload final models")
    }

    func modelsPresent() async -> Bool {
        true
    }

    func status() async -> ModelStatus {
        .ready
    }
}

/// Opens once; everything waiting on it then continues.
actor Gate {
    private var isOpen = false
    private var waiters: [CheckedContinuation<Void, Never>] = []
    private(set) var waiting = 0

    func wait() async {
        guard !isOpen else { return }
        waiting += 1
        await withCheckedContinuation { waiters.append($0) }
    }

    func open() {
        isOpen = true
        let resumed = waiters
        waiters = []
        resumed.forEach { $0.resume() }
    }
}

/// Loads "live models" that are only a decoder and a log entry.
struct FakeLiveModels: LiveModelLoading {
    let log: EventLog
    var decoder: any LiveDecoder = HoldingDecoder()
    /// When set, a load waits for it to open, as a first Neural Engine compile does.
    var loadGate: Gate?

    func load(model: String) async throws -> LoadedLiveModel {
        log.add("load live \(model)")
        await loadGate?.wait()
        let log = log
        return LoadedLiveModel(decoder: decoder) { log.add("unload live \(model)") }
    }
}

// MARK: - Decoder

/// Answers every decode with no words, and holds decodes while told to.
actor HoldingDecoder: LiveDecoder {
    private var isHolding = false
    private var held: [CheckedContinuation<Void, Never>] = []
    private(set) var started = 0
    private(set) var returned = 0

    func decode(_ samples: [Float], startTime: TimeInterval, options _: LiveDecodeOptions) async throws -> LiveDecodeResult {
        started += 1
        defer { returned += 1 }
        if isHolding {
            await withCheckedContinuation { held.append($0) }
        }
        let end = startTime + Double(samples.count) / LiveAudioChunk.sampleRate
        return LiveDecodeResult(hypothesis: Hypothesis(words: [], windowStart: startTime, windowEnd: end), language: "en")
    }

    func hold() {
        isHolding = true
    }

    func release() {
        isHolding = false
        let waiting = held
        held = []
        waiting.forEach { $0.resume() }
    }
}

// MARK: - Session

/// A live session the test drives: it yields what the test sends, and
/// records what the host asked of it.
actor ScriptedSession: LiveTranscriptionSession {
    nonisolated let updates: AsyncStream<LiveTrackUpdate>
    private let continuation: AsyncStream<LiveTrackUpdate>.Continuation
    private let log: EventLog
    private let finalUpdates: [LiveTrackUpdate]
    private let holdsFinish: Bool
    private var heldFinish: CheckedContinuation<[LiveTrackUpdate], Never>?
    private(set) var appended: [LiveAudioChunk] = []

    /// - Parameter holdsFinish: A finish waits until the session is cancelled,
    ///   then returns no updates, as `WhisperLiveSession` does.
    init(log: EventLog, finalUpdates: [LiveTrackUpdate] = [], holdsFinish: Bool = false) {
        self.log = log
        self.finalUpdates = finalUpdates
        self.holdsFinish = holdsFinish
        (updates, continuation) = AsyncStream.makeStream(of: LiveTrackUpdate.self, bufferingPolicy: .unbounded)
    }

    func start(_ config: LiveSessionConfig) async throws {
        log.add("start session \(config.generation)")
    }

    func append(_ chunk: LiveAudioChunk) async {
        appended.append(chunk)
    }

    func setUpdateInterval(_: TimeInterval) async {}

    func setPaused(_: Bool) async {}

    func finish(timeout _: Duration) async -> [LiveTrackUpdate] {
        log.add("finish session")
        guard holdsFinish else {
            continuation.finish()
            return finalUpdates
        }
        return await withCheckedContinuation { heldFinish = $0 }
    }

    func cancel() async {
        log.add("cancel session")
        heldFinish?.resume(returning: [])
        heldFinish = nil
        continuation.finish()
    }

    // MARK: Test controls

    func send(_ update: LiveTrackUpdate) {
        continuation.yield(update)
    }

    /// The engine failed: the stream ends without finish or cancel.
    func fail() {
        continuation.finish()
    }
}

/// Keeps the sessions the host made, so a test can drive them.
final class SessionFactory: Sendable {
    private let sessions = Mutex<[ScriptedSession]>([])
    private let log: EventLog
    private let finalUpdates: [LiveTrackUpdate]
    private let holdsFinish: Bool

    init(log: EventLog, finalUpdates: [LiveTrackUpdate] = [], holdsFinish: Bool = false) {
        self.log = log
        self.finalUpdates = finalUpdates
        self.holdsFinish = holdsFinish
    }

    var last: ScriptedSession? {
        sessions.withLock { $0.last }
    }

    func make(_: any LiveDecoder) -> any LiveTranscriptionSession {
        let session = ScriptedSession(log: log, finalUpdates: finalUpdates, holdsFinish: holdsFinish)
        sessions.withLock { $0.append(session) }
        return session
    }
}

// MARK: - Owner

/// A connection that started a live session.
final class RecordingOwner: LiveSessionOwner {
    private let delivered = Mutex<[LiveTrackUpdate]>([])
    private let ended = Mutex<[String]>([])

    var updates: [LiveTrackUpdate] {
        delivered.withLock { $0 }
    }

    var endedSessions: [String] {
        ended.withLock { $0 }
    }

    func deliver(_ update: LiveTrackUpdate) {
        delivered.withLock { $0.append(update) }
    }

    func sessionDidEnd(sessionID: UUID, generation: Int) {
        ended.withLock { $0.append("\(sessionID.uuidString) \(generation)") }
    }
}

// MARK: - Values

func liveConfig(model: String? = "live-model", generation: Int = 1, sessionID: UUID = UUID()) -> LiveSessionConfig {
    LiveSessionConfig(
        sessionID: sessionID,
        generation: generation,
        engine: .whisper,
        whisperModel: model,
        tracks: [.mic, .system],
        updateInterval: 1,
        language: .english,
        vocabulary: []
    )
}

func liveUpdate(_ config: LiveSessionConfig, track: LiveTrack = .mic, revision: Int, start: TimeInterval) -> LiveTrackUpdate {
    LiveTrackUpdate(
        sessionID: config.sessionID,
        generation: config.generation,
        track: track,
        revision: revision,
        rows: [LiveRow(track: track, startTime: start, endTime: start + 1, settledText: "row \(revision)", tailText: "")],
        gaps: [LiveGap(track: track, startTime: start, duration: 0.1, reason: .captureGap)],
        transcribedThrough: start + 1,
        settledThrough: start + 1
    )
}

func speech(_ track: LiveTrack = .mic, from start: TimeInterval, seconds: TimeInterval) -> [LiveAudioChunk] {
    let length = 0.25
    return (0 ..< Int(seconds / length)).map { index in
        LiveAudioChunk(track: track, startTime: start + Double(index) * length, samples: Array(repeating: 0.1, count: Int(length * LiveAudioChunk.sampleRate)))
    }
}

// MARK: - Clock

/// A clock that moves only when a test advances it.
final class ManualClock: Clock {
    struct Instant: InstantProtocol {
        var offset: Duration

        func advanced(by duration: Duration) -> Instant {
            Instant(offset: offset + duration)
        }

        func duration(to other: Instant) -> Duration {
            other.offset - offset
        }

        static func < (lhs: Instant, rhs: Instant) -> Bool {
            lhs.offset < rhs.offset
        }
    }

    private struct Sleeper {
        let id: UUID
        let deadline: Instant
        let continuation: CheckedContinuation<Void, any Error>
    }

    private let state = Mutex((now: Instant(offset: .zero), sleepers: [Sleeper]()))

    var now: Instant {
        state.withLock { $0.now }
    }

    var minimumResolution: Duration {
        .zero
    }

    var sleeperCount: Int {
        state.withLock { $0.sleepers.count }
    }

    func advance(by duration: Duration) {
        let due = state.withLock { state in
            state.now = state.now.advanced(by: duration)
            let now = state.now
            let due = state.sleepers.filter { $0.deadline <= now }
            state.sleepers.removeAll { $0.deadline <= now }
            return due
        }
        due.forEach { $0.continuation.resume() }
    }

    func sleep(until deadline: Instant, tolerance _: Duration?) async throws {
        let id = UUID()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                let resumeNow = state.withLock { state in
                    guard deadline > state.now else { return true }
                    state.sleepers.append(Sleeper(id: id, deadline: deadline, continuation: continuation))
                    return false
                }
                if resumeNow {
                    continuation.resume()
                }
            }
        } onCancel: {
            let cancelled = state.withLock { state in
                let match = state.sleepers.first { $0.id == id }
                state.sleepers.removeAll { $0.id == id }
                return match
            }
            cancelled?.continuation.resume(throwing: CancellationError())
        }
    }
}
