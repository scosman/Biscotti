import AudioCapture
import Foundation
import LiveTranscriptionService
import LiveTranscriptModel
import Synchronization
import Transcription

// MARK: - Engine

/// A live engine whose start, chunks, updates and finish the test controls.
public actor FakeLiveEngine: LiveEngineSession {
    public enum StartBehavior: Sendable {
        case succeed
        case fail(TranscriptionError)
        /// Waits until `releaseStart()` or `cancel()`.
        case hang
    }

    public enum FinishBehavior: Sendable {
        /// Returns these updates at once (their session and generation are
        /// filled in from the config).
        case returns([LiveTrackUpdate])
        /// Waits until `releaseFinish(_:)` or `cancel()`.
        case hang
    }

    public nonisolated let updates: AsyncStream<LiveTrackUpdate>
    private let continuation: AsyncStream<LiveTrackUpdate>.Continuation
    private let startBehavior: StartBehavior
    private var finishBehavior: FinishBehavior
    public private(set) var config: LiveSessionConfig?
    public private(set) var offered: [LiveAudioChunk] = []
    /// Every call to `offer`, taken or refused.
    public private(set) var offerAttempts = 0
    public private(set) var intervals: [TimeInterval] = []
    public private(set) var pausedCalls: [Bool] = []
    public private(set) var finishTimeouts: [Duration] = []
    public private(set) var isCancelled = false
    public var acceptsChunks = true
    private var startWaiter: CheckedContinuation<Void, any Error>?
    private var finishWaiter: CheckedContinuation<[LiveTrackUpdate], Never>?

    public init(start: StartBehavior = .succeed, finish: FinishBehavior = .returns([])) {
        startBehavior = start
        finishBehavior = finish
        (updates, continuation) = AsyncStream.makeStream(of: LiveTrackUpdate.self)
    }

    public func start(_ config: LiveSessionConfig) async throws {
        self.config = config
        switch startBehavior {
        case .succeed:
            return
        case let .fail(error):
            throw error
        case .hang:
            try await withCheckedThrowingContinuation { startWaiter = $0 }
        }
    }

    public func offer(_ chunk: LiveAudioChunk) async -> Bool {
        offerAttempts += 1
        guard acceptsChunks, !isCancelled else { return false }
        offered.append(chunk)
        return true
    }

    public func append(_ chunk: LiveAudioChunk) async {
        _ = await offer(chunk)
    }

    public func setUpdateInterval(_ seconds: TimeInterval) async {
        intervals.append(seconds)
    }

    public func setPaused(_ paused: Bool) async {
        pausedCalls.append(paused)
    }

    public func finish(timeout: Duration) async -> [LiveTrackUpdate] {
        finishTimeouts.append(timeout)
        let finals: [LiveTrackUpdate] = switch finishBehavior {
        case let .returns(updates): updates
        case .hang: await withCheckedContinuation { finishWaiter = $0 }
        }
        continuation.finish()
        return finals.map(stamped)
    }

    public func cancel() async {
        isCancelled = true
        startWaiter?.resume(throwing: TranscriptionError.cancelled)
        startWaiter = nil
        finishWaiter?.resume(returning: [])
        finishWaiter = nil
        continuation.finish()
    }

    // MARK: Test controls

    public func setAcceptsChunks(_ accepts: Bool) {
        acceptsChunks = accepts
    }

    public func setFinish(_ behavior: FinishBehavior) {
        finishBehavior = behavior
    }

    public func releaseStart() {
        startWaiter?.resume()
        startWaiter = nil
    }

    public func releaseFinish(_ updates: [LiveTrackUpdate] = []) {
        finishWaiter?.resume(returning: updates)
        finishWaiter = nil
    }

    /// Sends an update; its session and generation come from the config.
    public func emit(_ update: LiveTrackUpdate) {
        continuation.yield(stamped(update))
    }

    /// The engine fails: its updates end without a finish or cancel.
    public func fail() {
        continuation.finish()
    }

    public var isFinishing: Bool {
        finishWaiter != nil
    }

    private func stamped(_ update: LiveTrackUpdate) -> LiveTrackUpdate {
        var update = update
        if let config {
            update.sessionID = config.sessionID
            update.generation = config.generation
        }
        return update
    }
}

/// Makes `FakeLiveEngine`s, the nth with the nth start behavior (later ones
/// succeed), and keeps them for the test.
public final class FakeLiveEngineFactory: Sendable {
    private struct State {
        var engines: [FakeLiveEngine] = []
        var starts: [FakeLiveEngine.StartBehavior]
        let finish: FakeLiveEngine.FinishBehavior
    }

    private let state: Mutex<State>

    public init(starts: [FakeLiveEngine.StartBehavior] = [], finish: FakeLiveEngine.FinishBehavior = .returns([])) {
        state = Mutex(State(starts: starts, finish: finish))
    }

    public var make: LiveEngineFactory {
        { [self] in
            state.withLock { state in
                let start = state.starts.isEmpty ? .succeed : state.starts.removeFirst()
                let engine = FakeLiveEngine(start: start, finish: state.finish)
                state.engines.append(engine)
                return engine
            }
        }
    }

    public var engines: [FakeLiveEngine] {
        state.withLock(\.engines)
    }
}

// MARK: - Model, power, audio

public final class FakeLiveModel: LiveModelProviding {
    private struct State {
        var present: Bool
        var holdsDownloads: Bool
        var downloads = 0
        var waiter: CheckedContinuation<Void, Never>?
    }

    private let state: Mutex<State>
    private let downloadError: (any Error & Sendable)?

    /// - Parameter holdsDownloads: A download waits for `releaseDownload()`.
    public init(present: Bool = true, holdsDownloads: Bool = false, downloadError: (any Error & Sendable)? = nil) {
        state = Mutex(State(present: present, holdsDownloads: holdsDownloads))
        self.downloadError = downloadError
    }

    public func isPresent() -> Bool {
        state.withLock(\.present)
    }

    public func download(status: @escaping @Sendable (String) -> Void) async throws {
        status("Downloading")
        let holds = state.withLock { state in
            state.downloads += 1
            return state.holdsDownloads
        }
        if holds {
            await withCheckedContinuation { continuation in state.withLock { $0.waiter = continuation } }
        }
        if let downloadError { throw downloadError }
        state.withLock { $0.present = true }
    }

    public var downloadCount: Int {
        state.withLock(\.downloads)
    }

    public var isDownloadWaiting: Bool {
        state.withLock { $0.waiter != nil }
    }

    public func releaseDownload() {
        let waiter = state.withLock { state in
            defer { state.waiter = nil }
            return state.waiter
        }
        waiter?.resume()
    }
}

/// A power source whose changes the test sends.
public final class FakePowerSource: PowerStateProviding {
    private let state: Mutex<(current: PowerState, continuation: AsyncStream<PowerState>.Continuation?)>

    public init(_ current: PowerState = PowerState()) {
        state = Mutex((current: current, continuation: nil))
    }

    public var current: PowerState {
        state.withLock(\.current)
    }

    public func changes() -> AsyncStream<PowerState> {
        let (stream, continuation) = AsyncStream.makeStream(of: PowerState.self)
        state.withLock { $0.continuation = continuation }
        return stream
    }

    public func send(_ next: PowerState) {
        let continuation = state.withLock { state in
            state.current = next
            return state.continuation
        }
        continuation?.yield(next)
    }
}

/// One track of a scripted tap: the test pushes blocks; the pump drains them.
public final class ScriptedBlockSource: LiveBlockSource {
    private enum Block {
        case samples([Float], sampleRate: Double, channelCount: Int, startTime: TimeInterval)
        case gap(startTime: TimeInterval, duration: TimeInterval, kind: LiveAudioGapKind)
        case end(TimeInterval)
    }

    private let pending = Mutex<[Block]>([])

    public init() {}

    public func push(_ samples: [Float], sampleRate: Double = 16000, channelCount: Int = 1, at startTime: TimeInterval) {
        pending.withLock { $0.append(.samples(samples, sampleRate: sampleRate, channelCount: channelCount, startTime: startTime)) }
    }

    /// `seconds` of a 16 kHz tone from `startTime`, in 100 ms blocks.
    public func pushTone(seconds: TimeInterval, from startTime: TimeInterval, amplitude: Float = 0.3) {
        let block = 1600
        let blocks = Int((seconds * 16000 / Double(block)).rounded())
        for index in 0 ..< blocks {
            let samples = (0 ..< block).map { amplitude * sin(Float(index * block + $0) * 0.15) }
            push(samples, at: startTime + Double(index) * 0.1)
        }
    }

    public func pushGap(at startTime: TimeInterval, duration: TimeInterval, kind: LiveAudioGapKind) {
        pending.withLock { $0.append(.gap(startTime: startTime, duration: duration, kind: kind)) }
    }

    public func end(at time: TimeInterval) {
        pending.withLock { $0.append(.end(time)) }
    }

    public func drain(_ body: (LiveAudioBlock) -> Void) {
        let blocks = pending.withLock { pending in
            defer { pending = [] }
            return pending
        }
        for block in blocks {
            switch block {
            case let .samples(samples, sampleRate, channelCount, startTime):
                samples.withUnsafeBufferPointer {
                    body(LiveAudioBlock(startTime: startTime, kind: .samples($0, sampleRate: sampleRate, channelCount: channelCount)))
                }
            case let .gap(startTime, duration, kind):
                body(LiveAudioBlock(startTime: startTime, kind: .gap(duration: duration, kind: kind)))
            case let .end(time):
                body(LiveAudioBlock(startTime: time, kind: .end))
            }
        }
    }
}

public final class ScriptedTap: LiveAudioSource {
    public let mic = ScriptedBlockSource()
    public let system = ScriptedBlockSource()

    public init() {}

    public var micBlocks: any LiveBlockSource {
        mic
    }

    public var systemBlocks: any LiveBlockSource {
        system
    }

    /// Both tracks end, as when the recorder closes its tap.
    public func end(at time: TimeInterval) {
        mic.end(at: time)
        system.end(at: time)
    }
}

// MARK: - Helpers

/// A live service on fakes, with short timings. It keeps the drawer's state
/// in memory unless `defaults` is given, and a settled-text violation stops
/// the test.
@MainActor
public func makeFakeLiveService(
    engines: FakeLiveEngineFactory = FakeLiveEngineFactory(),
    model: FakeLiveModel = FakeLiveModel(),
    vocabulary: @escaping @Sendable (UUID) async -> [String] = { _ in [] },
    isEnabled: Bool = true,
    power: FakePowerSource = FakePowerSource(),
    defaults: UserDefaults? = nil,
    macLanguageCode: String? = "en",
    timing: LiveTiming = LiveTiming(publishInterval: .zero, stopDeadline: .seconds(5), pumpInterval: .milliseconds(5), finishMargin: .milliseconds(100))
) -> LiveTranscriptionService {
    LiveTranscriptionService(
        engine: engines.make,
        model: model,
        vocabulary: vocabulary,
        isEnabled: isEnabled,
        power: power,
        defaults: defaults,
        macLanguageCode: macLanguageCode,
        timing: timing,
        onSettledTextViolation: { assertionFailure($0) }
    )
}

/// An update on one track, for a fake engine to stamp and send.
public func liveUpdate(
    _ track: LiveTrack = .mic,
    revision: Int = 1,
    rows: [LiveRow] = [],
    gaps: [LiveGap] = [],
    transcribedThrough: TimeInterval = 0,
    settledThrough: TimeInterval = 0,
    detectedLanguage: String? = nil
) -> LiveTrackUpdate {
    LiveTrackUpdate(
        sessionID: UUID(),
        generation: 0,
        track: track,
        revision: revision,
        rows: rows,
        gaps: gaps,
        transcribedThrough: transcribedThrough,
        settledThrough: settledThrough,
        detectedLanguage: detectedLanguage
    )
}

/// Waits until `condition` holds, failing the test after five seconds.
@MainActor
public func waitUntil(
    _ what: String = "a condition",
    _ condition: @MainActor () async -> Bool
) async throws {
    for _ in 0 ..< 1000 {
        if await condition() { return }
        try await Task.sleep(for: .milliseconds(5))
    }
    throw WaitTimeout(what: what)
}

public struct WaitTimeout: Error, CustomStringConvertible {
    public let what: String

    public var description: String {
        "Timed out waiting for \(what)"
    }
}
