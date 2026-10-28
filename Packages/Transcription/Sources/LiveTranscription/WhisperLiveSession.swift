import Foundation
import LiveTranscriptModel
import os.log
import Transcription

/// The Whisper live engine: re-decodes each track's growing audio window and
/// turns the decodes into append-only rows with `LocalAgreementReducer`.
///
/// One decode runs at a time across all tracks. The XPC worker hosts this
/// session for the app.
///
/// Call `finish(timeout:)` or `cancel()` to end the session: the scheduler
/// task keeps it alive until then.
public actor WhisperLiveSession: LiveTranscriptionSession {
    public enum Scheduling: Sendable {
        /// A task checks every 100 ms and runs the work that is due.
        case automatic
        /// Nothing runs on its own: the owner calls `runScheduledWork()`,
        /// for example to replay audio on a virtual clock.
        case manual
    }

    struct Setup {
        let sessionID: UUID
        let generation: Int
        let tracks: [LiveTrack]
        let language: WhisperLanguage
        let vocabularyPrompt: String?
    }

    /// Audio dropped while paused, reported as one gap when the track resumes.
    struct PausedSpan {
        var start: TimeInterval
        var end: TimeInterval
        /// True while every dropped chunk was silent.
        var isSilent = true
    }

    enum Phase {
        case idle, running, finishing, ended
    }

    static let tick = Duration.milliseconds(100)
    /// A last word less likely than this stays out of the tail until a final
    /// decode, a decode after a second of silence, or a decode of a window as
    /// long as the forced boundary keeps it.
    static let unsureWordProbability: Float = 0.3
    static let log = Logger(subsystem: "net.scosman.biscotti", category: "live")

    public nonisolated let updates: AsyncStream<LiveTrackUpdate>
    private let continuation: AsyncStream<LiveTrackUpdate>.Continuation
    private let decoder: any LiveDecoder
    private let clock: SessionClock
    private let scheduling: Scheduling

    private(set) var phase = Phase.idle
    private var setup: Setup?
    private var updateInterval = Duration.seconds(2)
    private var isPaused = false
    private var tracks: [LiveTrack: TrackState] = [:]
    private var pausedSpans: [LiveTrack: PausedSpan] = [:]
    private var lockedLanguage: String?
    private var revision = 0
    /// Increases whenever a decode in flight must be ignored on return:
    /// when the session ends and when finishing runs out of time.
    private var epoch = 0
    /// When the latest catch-up decode ended.
    private var lastCatchUpDecodeEnd = Duration.zero
    private var schedulerTask: Task<Void, Never>?

    /// The lane serializes scheduler passes and finishing, so decodes never overlap.
    private var laneIsBusy = false
    private var laneWaiters: [CheckedContinuation<Void, Never>] = []

    private var finishWaiter: CheckedContinuation<[LiveTrackUpdate], Never>?
    private var finishTasks: [Task<Void, Never>] = []
    private var finishUpdates: [LiveTrack: LiveTrackUpdate] = [:]

    public init(decoder: any LiveDecoder, clock: some Clock<Duration> = ContinuousClock(), scheduling: Scheduling = .automatic) {
        self.decoder = decoder
        self.clock = SessionClock(clock)
        self.scheduling = scheduling
        (updates, continuation) = AsyncStream.makeStream(of: LiveTrackUpdate.self, bufferingPolicy: .unbounded)
    }

    // MARK: - LiveTranscriptionSession

    public func start(_ config: LiveSessionConfig) async throws {
        guard phase == .idle else { throw LiveSessionError.alreadyStarted }
        guard LiveSessionRules.isSupported(config.tracks) else { throw LiveSessionError.unsupportedTracks(config.tracks) }
        guard LiveSessionRules.isValidInterval(config.updateInterval) else { throw LiveSessionError.invalidUpdateInterval }
        setup = try Setup(
            sessionID: config.sessionID,
            generation: config.generation,
            tracks: config.tracks,
            language: WhisperLanguage(config.language),
            vocabularyPrompt: VocabularyFormatter.formatPrompt(from: config.vocabulary)
        )
        updateInterval = .seconds(config.updateInterval)
        phase = .running
        Self.log.notice("Live session started: \(config.tracks.count, privacy: .public) track(s), update every \(config.updateInterval, privacy: .public) s")
        if scheduling == .automatic {
            schedulerTask = Task(priority: .userInitiated) { await self.runScheduler() }
        }
    }

    public func append(_ chunk: LiveAudioChunk) async {
        guard phase == .running, setup?.tracks.contains(chunk.track) == true else { return }
        if isPaused {
            let start = tracks[chunk.track]?.audio.end ?? chunk.startTime
            var span = pausedSpans[chunk.track, default: PausedSpan(start: start, end: start)]
            span.end = chunk.endTime
            span.isSilent = span.isSilent && AudioLevel.isSilent(chunk.samples)
            pausedSpans[chunk.track] = span
            return
        }
        let pause = pausedSpans.removeValue(forKey: chunk.track)
        let gap = pause.map { TrackState.GapBefore(reason: .paused, isSilent: $0.isSilent) }
        if tracks[chunk.track] != nil {
            // Mutated in place, so the retained window is not copied for every chunk.
            tracks[chunk.track]?.receive(chunk, after: gap)
        } else {
            // The first audio of a track continues nothing, unless a pause came first.
            var state = TrackState(track: chunk.track, start: pause?.start ?? chunk.startTime, now: clock.elapsed())
            var first = chunk
            first.isDiscontinuity = false
            state.receive(first, after: gap)
            tracks[chunk.track] = state
        }
        tracks[chunk.track]?.lastReceivedAt = clock.elapsed()
    }

    /// A value outside 0 < seconds ≤ 60 is ignored.
    public func setUpdateInterval(_ seconds: TimeInterval) async {
        guard LiveSessionRules.isValidInterval(seconds) else {
            Self.log.error("Ignored an invalid live update interval: \(seconds, privacy: .public)")
            return
        }
        updateInterval = .seconds(seconds)
    }

    public func setPaused(_ paused: Bool) async {
        guard paused != isPaused else { return }
        isPaused = paused
        Self.log.notice("Live session \(paused ? "paused" : "resumed", privacy: .public)")
    }

    public func finish(timeout: Duration) async -> [LiveTrackUpdate] {
        guard phase == .running else { return [] }
        // The scheduler task is not cancelled: a decode it is running would
        // see the cancellation. It stops on its own once the phase changes.
        phase = .finishing
        let sleep = clock.sleep
        return await withCheckedContinuation { waiter in
            finishWaiter = waiter
            finishTasks = [
                Task(priority: .userInitiated) { await self.runFinishing() },
                Task {
                    do { try await sleep(timeout) } catch { return }
                    self.abandonFinishing()
                }
            ]
        }
    }

    public func cancel() async {
        guard phase != .ended else { return }
        Self.log.notice("Live session cancelled")
        let waiter = finishWaiter
        finishWaiter = nil
        end()
        waiter?.resume(returning: [])
    }

    // MARK: - Scheduling

    /// Runs one scheduler pass: the immediate work of every track, then at most
    /// one decode, for the due track decoded longest ago. With `.automatic`
    /// scheduling the session calls this every 100 ms itself.
    public func runScheduledWork() async {
        guard phase == .running else { return }
        await acquireLane()
        defer { releaseLane() }
        guard phase == .running, !isPaused, let setup else { return }

        let now = clock.elapsed()
        // A backlog is worked through before any streaming decode.
        if isCatchingUp {
            await runCatchUp(now: now, order: setup.tracks)
            return
        }
        for track in setup.tracks {
            doImmediateWork(on: track, now: now)
        }
        let waiting = setup.tracks.filter { tracks[$0]?.nextWork(now: now, interval: updateInterval)?.needsDecode == true }
        guard let track = waiting.min(by: { lastDecode(of: $0) < lastDecode(of: $1) }),
              let work = tracks[track]?.nextWork(now: now, interval: updateInterval)
        else { return }

        let isFinal = work != .decode
        if await decodeWindow(of: track, isFinal: isFinal), isFinal {
            finishWindow(of: track)
        }
    }

    /// Clients waiting for the lane. Tests use it to know a pass is queued.
    var laneWaiterCount: Int {
        laneWaiters.count
    }

    private func runScheduler() async {
        while phase == .running {
            do { try await clock.sleep(Self.tick) } catch { return }
            await runScheduledWork()
        }
    }

    private func lastDecode(of track: LiveTrack) -> Duration {
        tracks[track]?.lastDecodeAt ?? .zero
    }

    private func acquireLane() async {
        guard laneIsBusy else {
            laneIsBusy = true
            return
        }
        await withCheckedContinuation { laneWaiters.append($0) }
    }

    private func releaseLane() {
        if laneWaiters.isEmpty {
            laneIsBusy = false
        } else {
            laneWaiters.removeFirst().resume()
        }
    }

    /// Stops all work for good. Lane waiters are let go; they find the session ended.
    private func end() {
        phase = .ended
        epoch += 1
        schedulerTask?.cancel()
        finishTasks.forEach { $0.cancel() }
        tracks = [:]
        pausedSpans = [:]
        continuation.finish()
        let waiters = laneWaiters
        laneWaiters = []
        waiters.forEach { $0.resume() }
    }
}

// MARK: - Track work

extension WhisperLiveSession {
    private func doImmediateWork(on track: LiveTrack, now: Duration) {
        while let work = tracks[track]?.nextWork(now: now, interval: updateInterval), !work.needsDecode {
            switch work {
            case .finishWindow: finishWindow(of: track)
            case .commitTail: commitTail(of: track)
            case .skipSilence: skipSilence(of: track, now: now)
            case .decode: return
            }
        }
    }

    /// Decodes the whole window and feeds the result to the reducer.
    /// - Parameter isFinal: True when `finish()` follows at once, so an unsure
    ///   last word is kept: it is about to be committed either way.
    /// - Returns: False when the result was not used because the session ended,
    ///   failed or ran out of time meanwhile.
    private func decodeWindow(of track: LiveTrack, isFinal: Bool) async -> Bool {
        guard var state = tracks[track], let setup else { return false }
        let window = state.beginDecode(at: clock.elapsed())
        // From the forced-boundary length on, the reducer may trim past a
        // held-back word without committing it, so the word is kept.
        let windowLength = Double(window.samples.count) / LiveAudioChunk.sampleRate
        let keepsUnsureWord = isFinal || state.isInSilence || windowLength >= LocalAgreementReducer.forcedBoundaryWindow
        let options = LiveDecodeOptions(
            language: setup.language.code ?? lockedLanguage,
            vocabularyPrompt: setup.vocabularyPrompt,
            settledContext: state.reducer.settledText(before: window.start)
        )
        tracks[track] = state

        let decodeEpoch = epoch
        // Timed on its own clock: a replay's virtual clock stands still during a decode.
        let decodeStart = ContinuousClock.now
        let result: LiveDecodeResult
        do {
            result = try await decoder.decode(window.samples, startTime: window.start, options: options)
        } catch {
            if decodeEpoch == epoch {
                fail(error)
            }
            return false
        }
        let decodeMilliseconds = decodeStart.duration(to: .now).seconds * 1000
        guard decodeEpoch == epoch, tracks[track] != nil else { return false }

        lockLanguage(from: result)
        var hypothesis = result.hypothesis
        // A sound description still open at the window's end waits for a
        // decode that hears the rest of it. When none will, its opener was
        // stray, and only the opener goes.
        var openAnnotationStart = result.openAnnotationStart
        if keepsUnsureWord, let words = result.wordsWithoutOpener {
            hypothesis.words = words
            openAnnotationStart = nil
        }
        let unsureWord = hypothesis.words.last.flatMap { $0.probability < Self.unsureWordProbability && !keepsUnsureWord ? $0 : nil }
        if unsureWord != nil {
            hypothesis.words.removeLast()
        }
        tracks[track]?.heldBackWords = unsureWord != nil || openAnnotationStart != nil
        let heldBackFrom = [unsureWord?.start, openAnnotationStart].compactMap(\.self).min()
        guard let agreement = tracks[track]?.reducer.reduce(hypothesis, heldBackFrom: heldBackFrom) else { return false }
        if let trimPoint = agreement.trimPoint {
            tracks[track]?.audio.trimWindow(before: trimPoint)
        }
        emit(track, rows: agreement.rows, decodeMilliseconds: decodeMilliseconds)
        breakOtherRows(after: track)
        return true
    }

    /// Commits the window's rows and moves on to the run after the gap.
    private func finishWindow(of track: LiveTrack) {
        guard var state = tracks[track] else { return }
        let rows = state.reducer.finish()
        let gaps = state.audio.advanceToNextRun()
        state.reducer.resolveSilence(through: state.audio.window.start)
        tracks[track] = state
        for gap in gaps where gap.reason == .queueOverflow {
            Self.log.notice("Live audio dropped on \(track.rawValue, privacy: .public): \(gap.duration, privacy: .public) s\(gap.isSilent ? ", silent" : "", privacy: .public)")
        }
        emit(track, rows: rows, gaps: gaps)
        breakOtherRows(after: track)
    }

    private func commitTail(of track: LiveTrack) {
        guard var state = tracks[track] else { return }
        let rows = state.reducer.finish()
        state.reducer.resolveSilence(through: state.audio.end)
        state.audio.clearWindow()
        state.heldBackWords = false
        tracks[track] = state
        emit(track, rows: rows)
        breakOtherRows(after: track)
    }

    /// Everything decoded so far is settled and the new audio is silence, so
    /// the window can be dropped without losing anything.
    private func skipSilence(of track: LiveTrack, now: Duration) {
        guard var state = tracks[track] else { return }
        state.lastDecodeAt = now
        state.reducer.resolveSilence(through: state.audio.end)
        state.audio.clearWindow()
        tracks[track] = state
        emit(track)
    }

    /// When this track started speaking again, the other track's row that
    /// began earlier closes there, so its next words follow this track's row
    /// and the rows interleave like a conversation.
    private func breakOtherRows(after track: LiveTrack) {
        guard let setup, let start = tracks[track]?.reducer.latestSpeechStart,
              start > tracks[track]?.handledSpeechStart ?? -.infinity
        else { return }
        tracks[track]?.handledSpeechStart = start
        for other in setup.tracks where other != track {
            guard let rows = tracks[other]?.reducer.breakRow(at: start), !rows.isEmpty else { continue }
            emit(other, rows: rows)
        }
    }

    private func lockLanguage(from result: LiveDecodeResult) {
        guard setup?.language == .detect, lockedLanguage == nil, !result.hypothesis.words.isEmpty, let language = result.language else { return }
        lockedLanguage = language
        Self.log.notice("Live language detected: \(language, privacy: .public)")
    }

    private func emit(_ track: LiveTrack, rows: [LiveRow] = [], gaps: [LiveGap] = [], decodeMilliseconds: Double? = nil) {
        guard let setup, var state = tracks[track] else { return }
        let watermarks = state.watermarks
        guard !rows.isEmpty || !gaps.isEmpty || watermarks != state.reportedWatermarks else { return }
        state.reportedWatermarks = watermarks
        tracks[track] = state
        revision += 1
        let update = LiveTrackUpdate(
            sessionID: setup.sessionID,
            generation: setup.generation,
            track: track,
            revision: revision,
            rows: rows,
            gaps: gaps,
            transcribedThrough: watermarks.transcribedThrough,
            settledThrough: watermarks.settledThrough,
            detectedLanguage: lockedLanguage,
            decodeMilliseconds: decodeMilliseconds
        )
        switch phase {
        case .running:
            continuation.yield(update)
        case .finishing:
            if finishUpdates[track] == nil {
                finishUpdates[track] = update
            } else {
                finishUpdates[track]?.merge(update)
            }
        case .idle, .ended:
            break
        }
    }

    private func fail(_ error: any Error) {
        Self.log.error("Live decode failed; ending the session: \(error.localizedDescription, privacy: .public)")
        switch phase {
        case .running:
            end()
        case .finishing:
            abandonFinishing()
        case .idle, .ended:
            break
        }
    }
}

// MARK: - Finishing

extension WhisperLiveSession {
    private func runFinishing() async {
        await acquireLane()
        defer { releaseLane() }
        guard phase == .finishing, let setup else { return }
        endCatchUp()
        let finishEpoch = epoch
        for track in setup.tracks {
            await finishTrack(track)
            guard epoch == finishEpoch else { return }
        }
        Self.log.notice("Live session finished")
        completeFinishing()
    }

    /// Finishes every run of the track in order, each with a final decode where needed.
    private func finishTrack(_ track: LiveTrack) async {
        while let state = tracks[track] {
            if state.needsFinalDecode {
                guard await decodeWindow(of: track, isFinal: true) else { return }
            }
            guard tracks[track]?.audio.hasRunAfterWindow == true else { break }
            finishWindow(of: track)
        }
        finishLastWindow(of: track, markingIncomplete: false)
    }

    private func finishLastWindow(of track: LiveTrack, markingIncomplete: Bool) {
        let pause = pausedSpans.removeValue(forKey: track)
        guard var state = tracks[track] ?? pause.map({ TrackState(track: track, start: $0.start, now: clock.elapsed()) }) else { return }
        var rows = state.reducer.finish()
        if markingIncomplete {
            for index in rows.indices {
                rows[index].isIncomplete = true
            }
        }
        var gaps = markingIncomplete ? state.audio.runs.dropFirst().flatMap(\.gapsBefore) : []
        if !markingIncomplete {
            state.reducer.resolveSilence(through: state.audio.end)
        }
        if let pause, pause.end > state.audio.end {
            gaps.append(LiveGap(track: track, startTime: state.audio.end, duration: pause.end - state.audio.end, reason: .paused, isSilent: pause.isSilent))
            state.reducer.resolveSilence(through: pause.end)
        }
        tracks[track] = state
        emit(track, rows: rows, gaps: gaps)
        breakOtherRows(after: track)
    }

    /// Out of time, or a final decode failed: return what exists. The rows
    /// still open are committed as they are and marked incomplete, and the
    /// result of a decode still in flight is ignored.
    private func abandonFinishing() {
        guard phase == .finishing, finishWaiter != nil, let setup else { return }
        Self.log.notice("Live finish stopped early; the last rows are marked incomplete")
        epoch += 1
        endCatchUp()
        for track in setup.tracks {
            finishLastWindow(of: track, markingIncomplete: true)
        }
        completeFinishing()
    }

    private func completeFinishing() {
        guard let waiter = finishWaiter, let setup else { return }
        finishWaiter = nil
        let result = setup.tracks.compactMap { finishUpdates[$0] }
        end()
        waiter.resume(returning: result)
    }
}

// MARK: - Catch-up

/// Audio the app kept while no engine ran, or while this one fell behind,
/// arrives marked as backfill. A track with backfill catches up: it is
/// decoded once in long windows and its words are kept without a second,
/// agreeing decode. Kept words are settled in start-time order across tracks,
/// up to where every catching-up track has decoded and no further than any
/// other track's undecoded audio, so rows break where the other side starts
/// speaking, as in streaming. No streaming decode runs
/// while any track catches up; then the tracks stream from what is left.
extension WhisperLiveSession {
    /// Words ending this close to a catch-up window's end wait for the next
    /// window, which starts just before them: the window may cut them off.
    static let catchUpHoldBack: TimeInterval = 1
    /// A catching-up track that receives no audio for this long, counted
    /// from the latest catch-up decode's end, decodes what it holds and
    /// streams. Until a session has run this long, a track that has not sent
    /// audio yet holds back the other track's words.
    static let catchUpStall = Duration.seconds(2)

    var isCatchingUp: Bool {
        tracks.values.contains { $0.isCatchingUp || !$0.pendingCatchUpWords.isEmpty }
    }

    /// Runs the due catch-up decode of the track furthest behind.
    private func runCatchUp(now: Duration, order: [LiveTrack]) async {
        let due = order.compactMap { track in
            tracks[track]?.catchUpWork(
                now: now,
                interval: updateInterval,
                stallAfter: Self.catchUpStall,
                decodedAt: lastCatchUpDecodeEnd
            ).map { (track: track, work: $0) }
        }
        let behind = due.min { (tracks[$0.track]?.catchUpThrough ?? 0) < (tracks[$1.track]?.catchUpThrough ?? 0) }
        guard let behind else {
            // Nothing to decode now; a track that has started may let words go.
            releaseCatchUpWords(upTo: catchUpReleaseLimit(now: now))
            return
        }
        await decodeCatchUp(of: behind.track, work: behind.work)
    }

    /// What a catch-up decode kept, and where its window is trimmed.
    private struct CatchUpResult {
        var kept: [TimedWord] = []
        var through: TimeInterval
        var decodeMilliseconds: Double?
    }

    /// Decodes a catch-up window and keeps its words. Words near the end wait
    /// for the next window, unless a gap ends the audio there.
    private func decodeCatchUp(of track: LiveTrack, work: TrackState.CatchUpWork) async {
        guard var state = tracks[track], let setup else { return }
        let limit = work == .window ? Int(LiveAudioLimits.catchUpWindow * LiveAudioChunk.sampleRate) : nil
        let window = state.beginCatchUpDecode(at: clock.elapsed(), limit: limit)
        let options = LiveDecodeOptions(
            language: setup.language.code ?? lockedLanguage,
            vocabularyPrompt: setup.vocabularyPrompt,
            settledContext: state.reducer.settledText(before: window.start)
        )
        tracks[track] = state
        // Before a gap, or when no audio follows, nothing later can finish a
        // word cut off at the end: every word is kept.
        let keepsEveryWord = work != .window && work != .liveEdge
        guard let result = await catchUpResult(of: track, window: window, options: options, keepsEveryWord: keepsEveryWord) else { return }
        lastCatchUpDecodeEnd = clock.elapsed()

        tracks[track]?.audio.trimWindow(before: result.through)
        // What the decode left undecided is decoded again, by the next
        // catch-up decode, a streaming decode or the finish.
        tracks[track]?.audio.markWindowUndecoded()
        tracks[track]?.pendingCatchUpWords += result.kept
        let decodedThrough = max(tracks[track]?.catchUpThrough ?? result.through, result.through)
        tracks[track]?.catchUpThrough = decodedThrough
        tracks[track]?.reducer.noteDecoded(through: result.through)
        var gaps: [LiveGap] = []
        switch work {
        case .rest(endsRun: true):
            gaps = continueCatchUpAfterGap(on: track)
        case .rest(endsRun: false), .liveEdge:
            // What is left streams.
            tracks[track]?.endCatchUp()
        case .window:
            break
        }
        emit(track, gaps: gaps, decodeMilliseconds: result.decodeMilliseconds)
        releaseCatchUpWords(upTo: catchUpReleaseLimit(now: clock.elapsed()))
    }

    /// Decodes the window unless it is silent. Nil when the result is not
    /// used: the decode failed, or the session ended or ran out of time.
    private func catchUpResult(
        of track: LiveTrack,
        window: (samples: [Float], start: TimeInterval),
        options: LiveDecodeOptions,
        keepsEveryWord: Bool
    ) async -> CatchUpResult? {
        let windowEnd = window.start + Double(window.samples.count) / LiveAudioChunk.sampleRate
        let cut = keepsEveryWord ? windowEnd : windowEnd - Self.catchUpHoldBack
        var result = CatchUpResult(through: max(window.start, cut))
        guard !AudioLevel.isSilent(window.samples[...]) else { return result }
        let decodeEpoch = epoch
        let decodeStart = ContinuousClock.now
        let decoded: LiveDecodeResult
        do {
            decoded = try await decoder.decode(window.samples, startTime: window.start, options: options)
        } catch {
            if decodeEpoch == epoch { fail(error) }
            return nil
        }
        guard decodeEpoch == epoch, tracks[track] != nil else { return nil }
        result.decodeMilliseconds = decodeStart.duration(to: .now).seconds * 1000
        lockLanguage(from: decoded)
        // Before a gap or with no audio to follow, nothing later hears the
        // rest of a sound description left open: its opener was stray.
        let words = keepsEveryWord ? decoded.wordsWithoutOpener ?? decoded.hypothesis.words : decoded.hypothesis.words
        result.kept = keepsEveryWord ? words : Array(words.prefix { $0.end <= cut })
        // Never trim inside a word that waits for the next window, unless
        // the window would not move at all: then that word is dropped.
        if let next = words.dropFirst(result.kept.count).first, next.start > window.start {
            result.through = min(result.through, next.start)
        }
        // Otherwise a description left open is decoded again, whole, by the
        // next window, as a word that waits is.
        // TODO(live annotations): an opener at the window's start
        // (`open <= window.start`) still drops the words after it when the
        // speaker stops within 3 s. Read it as stray there too, with a
        // two-window catch-up test.
        if !keepsEveryWord, let open = decoded.openAnnotationStart, open > window.start {
            result.through = min(result.through, open)
        }
        return result
    }

    /// Moves past the gap after the decoded window; catch-up goes on there.
    private func continueCatchUpAfterGap(on track: LiveTrack) -> [LiveGap] {
        let gaps = tracks[track]?.audio.advanceToNextRun() ?? []
        if let start = tracks[track]?.audio.window.start {
            tracks[track]?.catchUpThrough = start
            tracks[track]?.reducer.noteDecoded(through: start)
        }
        for gap in gaps where gap.reason == .queueOverflow {
            Self.log.notice("Live audio dropped on \(track.rawValue, privacy: .public): \(gap.duration, privacy: .public) s\(gap.isSilent ? ", silent" : "", privacy: .public)")
        }
        return gaps
    }

    /// Kept words that start before this time can be settled: every
    /// catching-up track has decoded through it, and every other track's
    /// undecoded audio starts after it. Just after the start, a track that
    /// has not sent audio yet may still have backfill to come. Once no track
    /// catches up, everything goes.
    private func catchUpReleaseLimit(now: Duration) -> TimeInterval {
        guard let setup else { return .infinity }
        if now < Self.catchUpStall, setup.tracks.contains(where: { tracks[$0] == nil }) {
            return -.infinity
        }
        let states = setup.tracks.compactMap { tracks[$0] }
        guard states.contains(where: \.isCatchingUp) else { return .infinity }
        // A track still streaming may yet decode audio from its window's
        // start, and joins catch-up there once it falls behind.
        return states.map { $0.isCatchingUp ? $0.catchUpThrough : $0.audio.window.start }.min() ?? .infinity
    }

    /// Settles the kept words that start before `limit`, in start-time
    /// order across tracks, breaking the other track's row where one starts
    /// speaking. Each track's settled time follows, up to `limit`.
    private func releaseCatchUpWords(upTo limit: TimeInterval) {
        guard let setup else { return }
        var ready: [(track: LiveTrack, word: TimedWord)] = []
        for track in setup.tracks {
            guard let words = tracks[track]?.pendingCatchUpWords, !words.isEmpty else { continue }
            let count = words.prefix { $0.start < limit }.count
            ready += words.prefix(count).map { (track: track, word: $0) }
            tracks[track]?.pendingCatchUpWords.removeFirst(count)
        }
        var changed: [LiveTrack: [LiveRow]] = [:]
        for item in ready.sorted(by: { $0.word.start < $1.word.start }) {
            changed[item.track, default: []] += tracks[item.track]?.reducer.commitCatchUp([item.word]) ?? []
            guard let start = tracks[item.track]?.reducer.latestSpeechStart,
                  start > tracks[item.track]?.handledSpeechStart ?? -.infinity
            else { continue }
            tracks[item.track]?.handledSpeechStart = start
            for other in setup.tracks where other != item.track {
                changed[other, default: []] += tracks[other]?.reducer.breakRow(at: start) ?? []
            }
        }
        for track in setup.tracks {
            guard let through = tracks[track]?.catchUpThrough else { continue }
            tracks[track]?.reducer.resolveSilence(through: min(limit, through))
            emit(track, rows: Self.latestVersions(of: changed[track] ?? []))
        }
    }

    /// Ends catch-up on every track and settles what it kept: the finish
    /// decodes what is left the usual way.
    private func endCatchUp() {
        for track in Array(tracks.keys) {
            tracks[track]?.endCatchUp()
        }
        releaseCatchUpWords(upTo: .infinity)
    }

    /// The last version of each row, in time order.
    static func latestVersions(of rows: [LiveRow]) -> [LiveRow] {
        var latest: [UUID: LiveRow] = [:]
        var order: [UUID] = []
        for row in rows {
            if latest[row.id] == nil { order.append(row.id) }
            latest[row.id] = row
        }
        return order.compactMap { latest[$0] }.sorted { $0.startTime < $1.startTime }
    }
}
