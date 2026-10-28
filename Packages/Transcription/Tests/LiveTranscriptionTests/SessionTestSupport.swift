import Foundation
import LiveTranscriptModel
import Synchronization
@testable import LiveTranscription

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

    private struct State {
        var now = Instant(offset: .zero)
        var sleepers: [Sleeper] = []
    }

    private let state = Mutex(State())

    var now: Instant {
        state.withLock { $0.now }
    }

    /// Sleeps waiting for the clock to advance.
    var sleeperCount: Int {
        state.withLock { $0.sleepers.count }
    }

    var minimumResolution: Duration {
        .zero
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

    func advance(bySeconds seconds: TimeInterval) {
        advance(by: .seconds(seconds))
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

// MARK: - Decoder

/// What the fake decoder was asked to decode.
struct DecodeCall {
    let startTime: TimeInterval
    let sampleCount: Int
    /// The loudest sample, which tests use to tell tracks apart.
    let peak: Float
    let options: LiveDecodeOptions

    var windowEnd: TimeInterval {
        startTime + Double(sampleCount) / LiveAudioChunk.sampleRate
    }

    func hypothesis(_ words: [TimedWord]) -> Hypothesis {
        Hypothesis(words: words, windowStart: startTime, windowEnd: windowEnd)
    }
}

struct FakeDecoderError: Error {}

/// Answers decodes from a script, records every call and can hold calls
/// until a test releases them.
actor FakeDecoder: LiveDecoder {
    typealias Respond = @Sendable (_ call: DecodeCall, _ index: Int) throws -> LiveDecodeResult

    private(set) var calls: [DecodeCall] = []
    private(set) var running = 0
    private(set) var maxRunning = 0
    private var respond: Respond
    private var isHolding = false
    private var held: [CheckedContinuation<Void, Never>] = []

    /// Answers with the scripted words that have ended by the window end, as
    /// Whisper would hear them.
    init(script: [TimedWord] = [], language: String = "en") {
        respond = { call, _ in
            let heard = script.filter { $0.start >= call.startTime && $0.end <= call.windowEnd }
            return LiveDecodeResult(hypothesis: call.hypothesis(heard), language: language)
        }
    }

    init(respond: @escaping Respond) {
        self.respond = respond
    }

    /// Answers as `WhisperKitLiveDecoder` does for a script that holds sound
    /// descriptions or their openers: the heard words go through
    /// `NonSpeechAnnotations`.
    static func describingSounds(_ script: [TimedWord]) -> FakeDecoder {
        FakeDecoder { call, _ in
            let heard = script.filter { $0.start >= call.startTime && $0.end <= call.windowEnd }
            let spoken = NonSpeechAnnotations.removed(from: heard)
            return LiveDecodeResult(
                hypothesis: call.hypothesis(spoken.words),
                language: "en",
                openAnnotationStart: spoken.openFrom,
                wordsWithoutOpener: spoken.wordsWithoutOpener
            )
        }
    }

    func decode(_ samples: [Float], startTime: TimeInterval, options: LiveDecodeOptions) async throws -> LiveDecodeResult {
        let call = DecodeCall(startTime: startTime, sampleCount: samples.count, peak: samples.max() ?? 0, options: options)
        let index = calls.count
        calls.append(call)
        running += 1
        maxRunning = max(maxRunning, running)
        defer { running -= 1 }
        if isHolding {
            await withCheckedContinuation { held.append($0) }
        }
        return try respond(call, index)
    }

    func hold() {
        isHolding = true
    }

    /// Releases held calls and stops holding new ones.
    func release() {
        isHolding = false
        let waiting = held
        held = []
        waiting.forEach { $0.resume() }
    }

    var heldCount: Int {
        held.count
    }
}

// MARK: - Audio

enum Level {
    static let speech: Float = 0.1
    static let otherSpeech: Float = 0.2
    static let silence: Float = 0
}

/// Constant-level chunks covering `start ..< end`, 250 ms each.
func chunks(
    _ track: LiveTrack = .mic,
    from start: TimeInterval,
    to end: TimeInterval,
    level: Float = Level.speech,
    backfill: Bool = false
) -> [LiveAudioChunk] {
    let length = 0.25
    let count = Int(((end - start) / length).rounded())
    return (0 ..< count).map { index in
        LiveAudioChunk(
            track: track,
            startTime: start + Double(index) * length,
            samples: Array(repeating: level, count: Int(length * LiveAudioChunk.sampleRate)),
            isBackfill: backfill
        )
    }
}

func word(_ text: String, _ start: TimeInterval, _ end: TimeInterval, probability: Float = 0.9) -> TimedWord {
    TimedWord(text: " " + text, start: start, end: end, probability: probability)
}

/// Words `step` seconds apart, each `length` long.
func words(_ text: String, from start: TimeInterval, step: TimeInterval = 0.5, length: TimeInterval = 0.25) -> [TimedWord] {
    text.split(separator: " ").enumerated().map { index, text in
        let wordStart = start + Double(index) * step
        return word(String(text), wordStart, wordStart + length)
    }
}

// MARK: - Session

/// Both tracks by default; a test that feeds only the mic leaves the system track idle.
func config(
    tracks: [LiveTrack] = [.mic, .system],
    interval: TimeInterval = 1,
    language: LiveLanguage = .english,
    vocabulary: [String] = []
) -> LiveSessionConfig {
    LiveSessionConfig(
        sessionID: UUID(),
        generation: 1,
        engine: .whisper,
        whisperModel: "test",
        tracks: tracks,
        updateInterval: interval,
        language: language,
        vocabulary: vocabulary
    )
}

/// A session on a manual clock that runs work only when a test asks.
func manualSession(_ decoder: FakeDecoder, clock: ManualClock, config: LiveSessionConfig = config()) async throws -> WhisperLiveSession {
    let session = WhisperLiveSession(decoder: decoder, clock: clock, scheduling: .manual)
    try await session.start(config)
    return session
}

extension WhisperLiveSession {
    /// Plays chunks in real time: each is appended as it ends, then a pass runs.
    func play(_ chunks: [LiveAudioChunk], on clock: ManualClock) async {
        for chunk in chunks {
            await append(chunk)
            clock.advance(bySeconds: chunk.duration)
            await runScheduledWork()
        }
    }

    /// Plays both tracks side by side, chunk by chunk.
    func play(_ first: [LiveAudioChunk], alongside second: [LiveAudioChunk], on clock: ManualClock) async {
        for (one, other) in zip(first, second) {
            await append(one)
            await append(other)
            clock.advance(bySeconds: one.duration)
            await runScheduledWork()
        }
    }

    /// Every update the session sends until its stream ends.
    func collectedUpdates() async -> [LiveTrackUpdate] {
        var collected: [LiveTrackUpdate] = []
        for await update in updates {
            collected.append(update)
        }
        return collected
    }
}

/// The latest version of every row with text, in time order, as a store would hold them.
func latestRows(_ updates: [LiveTrackUpdate]) -> [LiveRow] {
    var latest: [UUID: LiveRow] = [:]
    for row in updates.flatMap(\.rows) {
        latest[row.id] = row
    }
    return latest.values.filter(\.hasText).sorted { $0.startTime < $1.startTime }
}

func text(of rows: [LiveRow]) -> String {
    rows.map { $0.settledText + $0.tailText }.joined(separator: " | ")
}

/// Polls `condition` until it holds or about two seconds pass.
func eventually(_ condition: @Sendable () async -> Bool) async -> Bool {
    for _ in 0 ..< 2000 {
        if await condition() {
            return true
        }
        try? await Task.sleep(for: .milliseconds(1))
    }
    return false
}
