import Foundation
import LiveTranscription
import LiveTranscriptModel
import os
import Synchronization
import Transcription

/// The service's timings. Tests shorten them.
public struct LiveTiming: Sendable {
    /// Observable state changes at most this often (4 times a second).
    public var publishInterval: Duration
    /// Draining the pump and finishing the engine after Stop share this deadline.
    public var stopDeadline: Duration
    public var pumpInterval: Duration
    /// The engine's own finish timeout ends this long before the deadline, so
    /// its incomplete tail comes back before the deadline cuts it off.
    public var finishMargin: Duration
    /// How long a language change waits for the old session's last words.
    public var languageSwitchTimeout: Duration
    /// How long after its session ends the worker lets a decode run before
    /// it counts as stuck and the worker ends itself
    /// (`LiveWorkerLimits.stuckDecode`). A language change waits this long
    /// on top of its timeout, plus `finishMargin`, before it gives up on the worker.
    public var workerStuckDecode: Duration

    public init(
        publishInterval: Duration = .milliseconds(250),
        stopDeadline: Duration = .seconds(10),
        pumpInterval: Duration = .milliseconds(50),
        finishMargin: Duration = .seconds(1),
        languageSwitchTimeout: Duration = .seconds(3),
        workerStuckDecode: Duration = LiveWorkerLimits.stuckDecode
    ) {
        self.publishInterval = publishInterval
        self.stopDeadline = stopDeadline
        self.pumpInterval = pumpInterval
        self.finishMargin = finishMargin
        self.languageSwitchTimeout = languageSwitchTimeout
        self.workerStuckDecode = workerStuckDecode
    }
}

/// What one recording's live session needs from the service.
struct LiveSessionSetup {
    let meetingID: UUID
    let source: any LiveAudioSource
    let makeEngine: LiveEngineFactory
    let vocabulary: [String]
    var language: LiveLanguage
    /// Audio before this recording time is not transcribed.
    let startTime: TimeInterval
    let timing: LiveTiming
    var power: PowerPolicy.Decision
    let onSettledTextViolation: @Sendable (String) -> Void
    /// Closes the app's other connection to the transcription worker (the
    /// one that keeps the live model loaded), so that once the live
    /// session's connection is closed too, a worker stuck in a decode exits
    /// and the next engine starts in a fresh one.
    let resetWorker: @MainActor () async -> Void
}

/// One recording's live transcript: its pump, its engine session (one per
/// generation), its store, and its end. The service mirrors the current
/// recording's session; a session still finishing after Stop writes only to
/// its own meeting's draft.
@MainActor
final class LiveRecordingSession {
    enum Phase: Equatable {
        case starting, running, restarting, switchingLanguage, finishing, ended
    }

    private static let log = Logger(subsystem: "net.scosman.biscotti", category: "live")
    /// How long a refused chunk first waits before it is offered again. Each
    /// further refusal doubles the wait, up to `maxOfferRetryDelay`, so an
    /// engine that stays busy is not polled 100 times a second.
    static let offerRetryDelay = Duration.milliseconds(10)
    static let maxOfferRetryDelay = Duration.milliseconds(160)
    /// The most unsettled audio per track kept for a restart: an engine may
    /// hold its lead (36 s) and the transit (4 s) past a settled time that
    /// lags its transcribed time by up to a catch-up window.
    static let unsettledLimit: TimeInterval = 120

    let meetingID: UUID
    let sessionID = UUID()
    private(set) var store: LiveTranscriptStore
    private(set) var phase = Phase.starting
    private(set) var unavailableReason: UnavailableReason?
    private(set) var isPaused: Bool
    /// Called, at most every `publishInterval`, when the transcript or status changed.
    var onChange: (@MainActor (LiveRecordingSession) -> Void)?
    var onLevel: (@MainActor (Float) -> Void)?

    private var setup: LiveSessionSetup
    private var generation = 0
    private var failures = 0
    private var engine: (any LiveEngineSession)?
    /// The engine of a start in progress, so a cancel can stop it.
    private var startingEngine: (any LiveEngineSession)?
    /// The engine finishing its words before a language change, so a cancel
    /// can stop it if the worker never replies.
    private var endingEngine: (any LiveEngineSession)?
    /// The language Detect found, kept for a restarted engine.
    private var lockedLanguage: String?
    private let pipe = LiveChunkPipe()
    private var pump: LiveAudioPump?
    private var tasks: [Task<Void, Never>] = []
    private var updatesTask: Task<Void, Never>?
    /// The end of the newest chunk each track's engine took.
    private var lastForwardedEnd: [LiveTrack: TimeInterval] = [:]
    /// The end of the newest chunk with sound each track's engine took, so a
    /// stretch it took but never settled is known to be silent or not.
    private var lastVoicedEnd: [LiveTrack: TimeInterval] = [:]
    /// The start of the first chunk each track's engine of this generation
    /// took: a new engine may take `engineLead` of audio from there before
    /// it reports progress.
    private var generationStart: [LiveTrack: TimeInterval] = [:]
    /// How far this generation's engine has transcribed each track, from its
    /// own updates. The store keeps an earlier generation's time, which a
    /// restarted engine has not reached.
    private var engineTranscribed: [LiveTrack: TimeInterval] = [:]
    /// The end of the newest chunk handed over while paused: the session
    /// drops paused audio as one gap, so it counts as handled.
    private var pausedThrough: [LiveTrack: TimeInterval] = [:]
    private let pumpEnded = SessionSignal()
    /// Set once every track's forwarder has ended.
    private let forwarderDone = SessionSignal()
    private var forwardersRunning = 0
    private var engineWaiters: [CheckedContinuation<Void, Never>] = []
    /// Forwarders waiting for the engine to transcribe further.
    private var progressWaiters: [CheckedContinuation<Void, Never>] = []
    /// Chunks the running engine took past its track's settled time, as
    /// 16-bit samples: a restart hands them to the next engine first.
    private var unsettled: [LiveTrack: [WaitingChunk]] = [:]
    /// Audio a restarted engine gets before newer chunks, per track, oldest first.
    private var replayQueue: [LiveTrack: [LiveAudioChunk]] = [:]
    /// Tracks whose replay task runs; their newer chunks wait until it ends.
    private var replaying: Set<LiveTrack> = []
    private var replayWaiters: [CheckedContinuation<Void, Never>] = []
    /// Offers in flight across the forwarders and replays.
    private var offersInFlight = 0
    private var offerWaiters: [CheckedContinuation<Void, Never>] = []
    private var publishScheduled = false
    private var lastPublish: ContinuousClock.Instant?
    private var stalledTracks: Set<LiveTrack> = []
    /// The power decision the running engine has, from its config or since.
    private var enginePower: PowerPolicy.Decision?
    private var isSyncingPower = false
    /// The engine's updates ended during the finish, before it was asked to
    /// finish: it failed, and nothing more will settle.
    private var engineEndedWhileFinishing = false
    /// The finish found the engine ended and did not ask it to finish.
    private var finishFoundEngineEnded = false
    /// In-app latency, for a hardware check.
    let latency: LiveLatency

    init(setup: LiveSessionSetup, latency: LiveLatency = LiveLatency()) {
        self.setup = setup
        self.latency = latency
        meetingID = setup.meetingID
        isPaused = setup.power.isPaused
        store = LiveTranscriptStore(sessionID: sessionID, startTime: setup.startTime, onSettledTextViolation: setup.onSettledTextViolation)
    }

    var status: LiveStatus {
        if let unavailableReason { return .unavailable(unavailableReason) }
        if isPaused { return .paused(.lowPowerHeat) }
        if !store.hasUpdates { return .starting }
        return store.isCatchingUp ? .catchingUp : .live
    }

    /// Starts the engine in the background, then the pump. There is no start
    /// timeout: the first load in a new build can take minutes.
    ///
    /// The spec starts the pump after the engine. It starts first here: the
    /// pump keeps up to `LivePumpCore.retention` of audio per track while the
    /// engine starts, more than the tap's own queues hold.
    func begin() {
        startForwarders()
        startPump()
        tasks.append(Task { [weak self] in await self?.startEngine() })
    }
}

// MARK: - Engine

extension LiveRecordingSession {
    private var configLanguage: LiveLanguage {
        if case .detect = setup.language, let lockedLanguage { return .locale(lockedLanguage) }
        return setup.language
    }

    private func isWaitingForEngine(_ generation: Int) -> Bool {
        generation == self.generation && [.starting, .restarting, .switchingLanguage].contains(phase)
    }

    private func startEngine() async {
        guard [.starting, .restarting, .switchingLanguage].contains(phase) else { return }
        generation += 1
        let generation = generation
        store.beginGeneration(generation)
        latency.generationChanged()
        generationStart = [:]
        engineTranscribed = [:]
        pausedThrough = [:]
        let engine = setup.makeEngine()
        let menuLanguage = setup.language
        let language = configLanguage
        var config = LiveTranscriptionDefaults.sessionConfig(
            sessionID: sessionID, generation: generation, language: language, vocabulary: setup.vocabulary
        )
        config.updateInterval = LiveTranscriptionDefaults.updateInterval * setup.power.intervalMultiplier
        Self.log.notice("Starting the live engine, generation \(generation, privacy: .public)")
        startingEngine = engine
        do {
            try await engine.start(config)
        } catch {
            startingEngine = nil
            await engine.cancel()
            guard isWaitingForEngine(generation) else { return }
            await engineFailed(error: error)
            return
        }
        startingEngine = nil
        guard isWaitingForEngine(generation) else {
            await engine.cancel()
            return
        }
        self.engine = engine
        phase = .running
        resumeEngineWaiters()
        watchUpdates(of: engine, generation: generation)
        Self.log.notice("The live engine runs, generation \(generation, privacy: .public)")
        publishSoon()
        enginePower = PowerPolicy.Decision(intervalMultiplier: setup.power.intervalMultiplier, isPaused: false)
        await syncEnginePower()
        // The language changed while the engine started.
        if setup.language != menuLanguage { await restartWithCurrentLanguage() }
    }

    private func watchUpdates(of engine: any LiveEngineSession, generation: Int) {
        updatesTask = Task { [weak self] in
            for await update in engine.updates {
                self?.receive(update)
            }
            await self?.updatesEnded(generation: generation)
        }
    }

    private func receive(_ update: LiveTrackUpdate) {
        guard store.apply(update) else { return }
        latency.updateApplied(update)
        if lockedLanguage == nil, let code = update.detectedLanguage { lockedLanguage = code }
        if update.generation == generation {
            engineTranscribed[update.track] = max(engineTranscribed[update.track] ?? update.transcribedThrough, update.transcribedThrough)
        }
        let settled = store.settledThrough(update.track)
        if let chunks = unsettled[update.track] {
            unsettled[update.track] = Array(chunks.drop { $0.endTime <= settled + LiveTranscriptStore.gapJoinTolerance })
        }
        resumeProgressWaiters()
        publishSoon()
    }

    /// The engine's updates ended. While it ran, it failed and restarts.
    /// During the finish, the audio still waiting has nowhere to go: the
    /// forwarder stops handing it over, so the finish ends without waiting
    /// for the deadline. A finish the engine completed ends them too, after
    /// the forwarder is done.
    private func updatesEnded(generation: Int) async {
        guard generation == self.generation else { return }
        switch phase {
        case .running:
            Self.log.error("The live engine ended on its own, generation \(generation, privacy: .public)")
            await engineFailed(error: nil)
        case .finishing:
            engineEndedWhileFinishing = true
            resumeProgressWaiters()
        default:
            break
        }
    }

    /// Restarts once from the current time; a second failure stops live
    /// transcription for this recording. The transcript keeps what it has.
    private func engineFailed(error: (any Error)?) async {
        if (error as? TranscriptionError) == .needsDownload {
            await becomeUnavailable(.modelMissing)
            return
        }
        failures += 1
        // Set before any wait, so the forwarder holds its chunks for the next
        // engine instead of finding none.
        phase = .restarting
        if let failed = engine {
            engine = nil
            await waitUntilNotOffering()
            await failed.cancel()
        }
        guard phase == .restarting else { return }
        guard failures < 2 else {
            Self.log.error("The live engine failed again; live transcription stops for this recording")
            await becomeUnavailable(.stopped)
            return
        }
        Self.log.notice("Restarting the live engine")
        // The spec restarted "from the current time", with a gap for what the
        // failed engine took but had not settled. The user chose backfill
        // (2026-10-25): that audio goes to the new engine first, and the
        // audio that arrives meanwhile waits in the pipe and the pump, up to
        // `LivePumpCore.retention`, and follows it.
        replayUnsettledAudio()
        await startEngine()
    }

    /// What the engine took but never settled, at a Stop or a finish that
    /// did not complete, is lost. It was silent when no chunk with sound
    /// ends after the settled time.
    private func recordRestartGaps() {
        for track in lastForwardedEnd.keys {
            recordRestartGap(on: track)
        }
        publishSoon()
    }

    /// Audio no engine took, still waiting in the pump, the pipe or a
    /// replay when the finish ended, is missing from the live transcript.
    /// It was silent when no chunk with sound ends after where it starts.
    private func recordUnforwardedGaps() async {
        // Read before the await, as `recordRestartGaps` did: a chunk handed
        // over meanwhile goes to an engine about to be cancelled.
        let forwarded = lastForwardedEnd
        let extents = await pump?.chunkExtents() ?? [:]
        for (track, extent) in extents {
            let from = forwarded[track] ?? store.settledThrough(track)
            guard extent.end - from > LiveTranscriptStore.gapJoinTolerance else { continue }
            let isSilent = (extent.voicedEnd ?? -.infinity) <= from + LiveTranscriptStore.gapJoinTolerance
            store.addGap(LiveGap(track: track, startTime: from, duration: extent.end - from, reason: .queueOverflow, isSilent: isSilent))
        }
        publishSoon()
    }

    private func recordRestartGap(on track: LiveTrack) {
        guard let end = lastForwardedEnd[track] else { return }
        let from = store.settledThrough(track)
        // A finish that settled everything ends level with the audio, give
        // or take rounding, which must not show as a gap.
        guard end - from > LiveTranscriptStore.gapJoinTolerance else { return }
        let isSilent = (lastVoicedEnd[track] ?? -.infinity) <= from + LiveTranscriptStore.gapJoinTolerance
        store.addGap(LiveGap(track: track, startTime: from, duration: end - from, reason: .engineRestart, isSilent: isSilent))
    }

    private func becomeUnavailable(_ reason: UnavailableReason) async {
        unavailableReason = reason
        phase = .ended
        await tearDown()
        publishNow()
    }
}

// MARK: - Audio

extension LiveRecordingSession {
    private func startPump() {
        let pump = LiveAudioPump(source: setup.source, pipe: pipe, discardBefore: setup.startTime, interval: setup.timing.pumpInterval)
        self.pump = pump
        let events = pump.events
        tasks.append(Task { [weak self] in
            for await event in events {
                self?.handle(event)
            }
            self?.pumpEnded.set()
        })
        pump.start()
    }

    private func handle(_ event: LiveAudioPump.Event) {
        switch event {
        case let .progress(captured):
            store.recordCapture(captured)
            logStalledTracks()
            publishSoon()
        case let .gap(gap):
            store.addGap(gap)
            publishSoon()
        case let .level(level):
            onLevel?(level)
        case .ended:
            break
        }
    }

    private func logStalledTracks() {
        let stalled = Set(store.captured.keys.filter { !store.isActive($0) })
        guard stalled != stalledTracks else { return }
        for track in stalled.subtracting(stalledTracks) {
            Self.log.notice("The live \(track.rawValue, privacy: .public) track stopped delivering audio")
        }
        for track in stalledTracks.subtracting(stalled) {
            Self.log.notice("The live \(track.rawValue, privacy: .public) track delivers audio again")
        }
        stalledTracks = stalled
    }

    /// One forwarder per track, so a track waiting for its engine to catch
    /// up does not hold up the other.
    private func startForwarders() {
        forwardersRunning = pipe.tracks.count
        for track in pipe.tracks {
            let chunks = pipe.chunks(of: track)
            tasks.append(Task { [weak self] in
                for await chunk in chunks {
                    guard let self else { return }
                    await forward(chunk)
                }
                self?.forwarderEnded()
            })
        }
    }

    /// The finish waits for the forwarders and any replay.
    private func forwarderEnded() {
        forwardersRunning -= 1
        if forwardersRunning <= 0, replaying.isEmpty { forwarderDone.set() }
    }

    /// Hands one chunk to the engine, after a start or restart if one is
    /// under way, once the engine has transcribed the track to within
    /// `engineLead` of the chunk's end. A chunk handed over more than
    /// `backfillLag` behind the track's newest audio is backfill, which the
    /// engine catches up on. A chunk the engine refuses (8 of its track
    /// unacknowledged, or the engine failing) is offered again; meanwhile
    /// newer audio waits in the pipe and the pump, which drops only audio
    /// beyond its retention.
    ///
    /// Once the engine ended during the finish, chunks are dropped; they count
    /// as taken, so the gap for the lost stretch covers them.
    private func forward(_ chunk: LiveAudioChunk) async {
        defer { pipe.release(chunk.track) }
        await deliver(chunk, isReplay: false)
    }

    enum Delivery {
        case taken
        /// A restart rebuilt the replay: the chunk is no longer its head.
        case replayRebuilt
        /// No engine is left to take it.
        case noEngine
    }

    /// Offers the chunk until an engine takes it or none is left. Newer
    /// audio waits while its track's unsettled audio is replayed.
    @discardableResult
    private func deliver(_ chunk: LiveAudioChunk, isReplay: Bool) async -> Delivery {
        var chunk = chunk
        var retryDelay = Self.offerRetryDelay
        while let engine = await currentEngine() {
            guard !engineEndedWhileFinishing else {
                noteTaken(chunk)
                return .taken
            }
            guard isReplay || !replaying.contains(chunk.track) else {
                await withCheckedContinuation { replayWaiters.append($0) }
                continue
            }
            // A restart rebuilt the replay with older audio first.
            if isReplay, replayQueue[chunk.track]?.first?.startTime != chunk.startTime { return .replayRebuilt }
            // Paused audio is dropped as one gap, so it never waits for progress.
            let isPausedNow = isPaused
            guard isPausedNow || isWithinLead(chunk) else {
                await waitForProgress()
                continue
            }
            chunk.isBackfill = isBackfill(chunk)
            offersInFlight += 1
            let taken = await engine.offer(chunk)
            offersInFlight -= 1
            if offersInFlight == 0 { resumeOfferWaiters() }
            if taken, isPausedNow {
                pausedThrough[chunk.track] = max(pausedThrough[chunk.track] ?? chunk.endTime, chunk.endTime)
            }
            if taken {
                noteTaken(chunk)
                if !isPausedNow, !isReplay, !chunk.isBackfill { latency.chunkTaken(chunk) }
                return .taken
            }
            do { try await Task.sleep(for: retryDelay) } catch { return .noEngine }
            retryDelay = min(retryDelay * 2, Self.maxOfferRetryDelay)
        }
        return .noEngine
    }

    /// True when this generation's engine has transcribed the chunk's track
    /// to within `engineLead` of its end, or has taken nothing of the track
    /// yet. Audio handed over while paused counts as handled.
    private func isWithinLead(_ chunk: LiveAudioChunk) -> Bool {
        guard let start = generationStart[chunk.track] else { return true }
        let base = max(start, engineTranscribed[chunk.track] ?? start, pausedThrough[chunk.track] ?? start)
        return chunk.endTime <= base + LiveAudioLimits.engineLead
    }

    private func isBackfill(_ chunk: LiveAudioChunk) -> Bool {
        let captured = store.captured[chunk.track] ?? chunk.endTime
        return captured - chunk.endTime > LiveAudioLimits.backfillLag
    }

    private func waitForProgress() async {
        await withCheckedContinuation { progressWaiters.append($0) }
    }

    private func resumeProgressWaiters() {
        let waiting = progressWaiters
        progressWaiters = []
        waiting.forEach { $0.resume() }
    }

    private func noteTaken(_ chunk: LiveAudioChunk) {
        if generationStart[chunk.track] == nil {
            generationStart[chunk.track] = chunk.startTime
        }
        // A replay hands over audio again: the newest end stays.
        lastForwardedEnd[chunk.track] = max(lastForwardedEnd[chunk.track] ?? chunk.endTime, chunk.endTime)
        if !AudioLevel.isSilent(chunk.samples) {
            lastVoicedEnd[chunk.track] = max(lastVoicedEnd[chunk.track] ?? chunk.endTime, chunk.endTime)
        }
        var kept = unsettled[chunk.track, default: []]
        kept.append(WaitingChunk(chunk))
        // Trimmed from the settled time on each update; this bound only
        // matters for an engine that stops settling. A replay records a gap
        // for what it no longer holds.
        while let oldest = kept.first, chunk.endTime - oldest.startTime > Self.unsettledLimit {
            kept.removeFirst()
        }
        unsettled[chunk.track] = kept
    }

    /// Hands each track's unsettled audio to the next engine, from the
    /// track's settled time, before newer chunks. A replay still running
    /// keeps what it has not delivered, after what the failed engine took.
    /// Audio the replay no longer holds, from the settled time on, is a gap.
    private func replayUnsettledAudio() {
        let taken = unsettled
        unsettled = [:]
        for track in Set(taken.keys).union(replayQueue.keys) {
            let from = store.settledThrough(track)
            let chunks = (taken[track] ?? []).map(\.chunk) + (replayQueue[track] ?? [])
            let replay = Self.replayChunks(chunks, from: from)
            if let first = replay.first, first.startTime - from > LiveTranscriptStore.gapJoinTolerance {
                store.addGap(LiveGap(track: track, startTime: from, duration: first.startTime - from, reason: .engineRestart))
            }
            replayQueue[track] = replay.isEmpty ? nil : replay
            guard !replay.isEmpty, !replaying.contains(track) else { continue }
            replaying.insert(track)
            Self.log.notice("Replaying \(replay.count, privacy: .public) unsettled live chunks on \(track.rawValue, privacy: .public)")
            tasks.append(Task { [weak self] in
                while let chunk = self?.replayQueue[track]?.first {
                    guard let self else { return }
                    switch await deliver(chunk, isReplay: true) {
                    case .taken:
                        if replayQueue[track]?.first?.startTime == chunk.startTime {
                            replayQueue[track]?.removeFirst()
                        }
                        if replayQueue[track]?.isEmpty == true { replayQueue[track] = nil }
                    case .replayRebuilt:
                        continue
                    case .noEngine:
                        replayQueue[track] = nil
                    }
                }
                self?.replayEnded(on: track)
            })
        }
    }

    /// The chunks in time order from `time` on, the first trimmed there,
    /// without repeats.
    static func replayChunks(_ chunks: [LiveAudioChunk], from time: TimeInterval) -> [LiveAudioChunk] {
        var replay: [LiveAudioChunk] = []
        for chunk in chunks.sorted(by: { $0.startTime < $1.startTime }) {
            let from = max(time, replay.last?.endTime ?? time)
            guard let part = replayChunk(chunk, from: from) else { continue }
            replay.append(part)
        }
        return replay
    }

    /// The part of `chunk` after `time`, nil when none is.
    static func replayChunk(_ chunk: LiveAudioChunk, from time: TimeInterval) -> LiveAudioChunk? {
        guard chunk.endTime > time + LiveTranscriptStore.gapJoinTolerance else { return nil }
        guard chunk.startTime < time else { return chunk }
        let skip = min(chunk.samples.count, Int(((time - chunk.startTime) * LiveAudioChunk.sampleRate).rounded()))
        var trimmed = chunk
        trimmed.startTime = chunk.startTime + Double(skip) / LiveAudioChunk.sampleRate
        trimmed.samples = Array(chunk.samples[skip...])
        return trimmed
    }

    private func replayEnded(on track: LiveTrack) {
        replaying.remove(track)
        let waiting = replayWaiters
        replayWaiters = []
        waiting.forEach { $0.resume() }
        if forwardersRunning <= 0, replaying.isEmpty { forwarderDone.set() }
    }

    private func currentEngine() async -> (any LiveEngineSession)? {
        while engine == nil, [.starting, .restarting, .switchingLanguage].contains(phase) {
            await withCheckedContinuation { engineWaiters.append($0) }
        }
        return engine
    }

    /// Engine changes also wake forwarders waiting for progress: a new
    /// engine takes audio from where it starts.
    private func resumeEngineWaiters() {
        let waiting = engineWaiters
        engineWaiters = []
        waiting.forEach { $0.resume() }
        resumeProgressWaiters()
    }

    private func waitUntilNotOffering() async {
        while offersInFlight > 0 {
            await withCheckedContinuation { offerWaiters.append($0) }
        }
    }

    private func resumeOfferWaiters() {
        let waiting = offerWaiters
        offerWaiters = []
        waiting.forEach { $0.resume() }
    }
}

// MARK: - Changes

extension LiveRecordingSession {
    /// A language change applies from now: the running engine finishes its
    /// words, then a new generation starts with the new language.
    func switchLanguage(to language: LiveLanguage) async {
        guard language != setup.language else { return }
        setup.language = language
        lockedLanguage = nil
        // A start under way switches once its engine runs.
        await restartWithCurrentLanguage()
    }

    /// The worker replies to the old engine's finish once its last decode
    /// returns, which a slow decode can delay past the finish's own timeout;
    /// a decode that never returns makes the worker end itself after
    /// `workerStuckDecode`, which ends the finish too. Only a worker that
    /// never replies at all is given up on, after both: the finish is
    /// cancelled and the worker reset, so the new engine starts in a fresh
    /// one. A healthy worker keeps the live model loaded.
    private func restartWithCurrentLanguage() async {
        guard phase == .running, let old = engine else { return }
        phase = .switchingLanguage
        engine = nil
        endingEngine = old
        await waitUntilNotOffering()
        let timing = setup.timing
        let finals = SwitchFinals()
        let finishedInTime = await Self.finishes(within: timing.languageSwitchTimeout + timing.workerStuckDecode + timing.finishMargin) {
            finals.updates = await old.finish(timeout: timing.languageSwitchTimeout)
        }
        if !finishedInTime, phase == .switchingLanguage {
            Self.log.error("The transcription worker did not answer the language change; resetting it")
            await old.cancel()
            await setup.resetWorker()
        }
        // Cleared only now: a Stop during the reset still reports the change
        // unfinished, so the final pass gets a fresh worker too.
        endingEngine = nil
        guard phase == .switchingLanguage else { return }
        for update in finals.updates {
            store.apply(update)
        }
        // A finish that timed out left the old engine's undecoded audio
        // behind: the new engine gets it first.
        replayUnsettledAudio()
        await startEngine()
    }

    func applyPower(_ decision: PowerPolicy.Decision) async {
        setup.power = decision
        isPaused = decision.isPaused
        // A pause lets forwarders waiting for progress hand over audio the
        // session drops as one gap; a resume lets them check again.
        resumeProgressWaiters()
        publishSoon()
        await syncEnginePower()
    }

    /// Brings the running engine to the latest power decision. One call runs
    /// at a time and loops until the engine has the latest, so decisions that
    /// arrive while it waits on the engine never land out of order.
    private func syncEnginePower() async {
        guard !isSyncingPower else { return }
        isSyncingPower = true
        defer { isSyncingPower = false }
        while let engine, enginePower != setup.power {
            let generation = generation
            let target = setup.power
            if enginePower?.intervalMultiplier != target.intervalMultiplier {
                let interval = LiveTranscriptionDefaults.updateInterval * target.intervalMultiplier
                Self.log.notice("The live engine updates every \(interval, privacy: .public) s")
                await engine.setUpdateInterval(interval)
            }
            if enginePower?.isPaused != target.isPaused {
                await engine.setPaused(target.isPaused)
            }
            // A restart meanwhile gave the new engine its own starting point.
            if generation == self.generation { enginePower = target }
        }
    }
}

// MARK: - End

extension LiveRecordingSession {
    /// After Stop: waits for the pump to drain the closed tap, then for the
    /// engine's last words, all under one deadline. On time-out the tail
    /// keeps what it has, marked incomplete, and the engine is cancelled.
    func finish() async -> LiveFinishResult {
        guard phase == .running, engine != nil else {
            // Starting, restarting, switching language or unavailable: no
            // engine will settle the tails the draft keeps, or the audio an
            // earlier engine took.
            let switchWasWaiting = endingEngine != nil
            store.markTailsIncomplete()
            recordRestartGaps()
            await recordUnforwardedGaps()
            await cancel()
            return switchWasWaiting ? .languageSwitchUnfinished : .nothingToFinish
        }
        phase = .finishing
        let deadline = setup.timing.stopDeadline
        let margin = setup.timing.finishMargin
        let startedAt = ContinuousClock.now
        let finishedInTime = await Self.finishes(within: deadline) { [weak self] in
            guard let self else { return }
            await pumpEnded.wait()
            await forwarderDone.wait()
            guard phase == .finishing, let engine else { return }
            if engineEndedWhileFinishing {
                finishFoundEngineEnded = true
                Self.log.error("The live engine ended before its finish; the draft keeps what it has")
            } else {
                let remaining = deadline - (ContinuousClock.now - startedAt) - margin
                let finals = await engine.finish(timeout: max(remaining, .zero))
                guard phase == .finishing else { return }
                for update in finals {
                    store.apply(update)
                }
            }
            // A finish commits every word and settles all the audio the
            // engine took. A tail or audio left now could not settle: the
            // worker failed or ran out of time. After a clean finish both are
            // no-ops.
            store.markTailsIncomplete()
            recordRestartGaps()
        }
        guard phase == .finishing else { return .cancelled }
        phase = .ended
        if !finishedInTime {
            Self.log.error("The live finish ran out of time; the draft keeps what it has")
            store.markTailsIncomplete()
            recordRestartGaps()
            await recordUnforwardedGaps()
        }
        await tearDown()
        publishNow()
        if !finishedInTime { return .timedOut }
        return finishFoundEngineEnded ? .engineLost : .finished
    }

    /// Stops everything at once: a new recording, or live transcription
    /// turned off. A draft keeps what it has, its tail marked incomplete.
    func cancel() async {
        guard phase != .ended else { return }
        if phase == .finishing { store.markTailsIncomplete() }
        phase = .ended
        await tearDown()
        publishNow()
    }

    private func tearDown() async {
        latency.end()
        logGaps()
        tasks.forEach { $0.cancel() }
        updatesTask?.cancel()
        resumeEngineWaiters()
        let engines = [engine, startingEngine, endingEngine].compactMap(\.self)
        engine = nil
        startingEngine = nil
        endingEngine = nil
        for engine in engines {
            await engine.cancel()
        }
        await pump?.stop()
        pipe.finish()
        pumpEnded.set()
        forwarderDone.set()
    }
}

/// The old engine's last words during a language change, written by the
/// bounded finish when it returns in time.
@MainActor
private final class SwitchFinals {
    var updates: [LiveTrackUpdate] = []
}

// MARK: - Logging

extension LiveRecordingSession {
    /// How many gaps the end-of-session log line lists.
    static let loggedGapLimit = 20

    /// The session's gaps, for a hardware check: what the live path missed,
    /// and why. No transcript text.
    private func logGaps() {
        let gaps = store.gaps
        var detail = gaps.prefix(Self.loggedGapLimit).map { gap in
            let times = String(format: "%.2f+%.2f s", gap.startTime, gap.duration)
            return "\(gap.track.rawValue) \(times) \(gap.reason)\(gap.isSilent ? " silent" : "")"
        }.joined(separator: "; ")
        if gaps.count > Self.loggedGapLimit { detail += "; \(gaps.count - Self.loggedGapLimit) more" }
        let rows = store.rows.count
        Self.log.notice("Live session ended with \(rows, privacy: .public) rows and \(gaps.count, privacy: .public) gaps. \(detail, privacy: .public)")
    }
}

// MARK: - Publishing

extension LiveRecordingSession {
    private func publishSoon() {
        guard !publishScheduled else { return }
        let interval = setup.timing.publishInterval
        let now = ContinuousClock.now
        guard let last = lastPublish, now - last < interval else {
            publishNow()
            return
        }
        publishScheduled = true
        let wait = interval - (now - last)
        Task { [weak self] in
            try? await Task.sleep(for: wait)
            self?.publishScheduled = false
            self?.publishNow()
        }
    }

    func publishNow() {
        lastPublish = .now
        onChange?(self)
    }

    /// Runs `work` and returns whether it finished within `deadline`. Work that
    /// runs late is left running; the caller stops it.
    private static func finishes(within deadline: Duration, _ work: @escaping @MainActor () async -> Void) async -> Bool {
        await withCheckedContinuation { continuation in
            let outcome = FirstOutcome(continuation)
            let timer = Task {
                do { try await Task.sleep(for: deadline) } catch { return }
                outcome.resume(false)
            }
            Task { @MainActor in
                await work()
                outcome.resume(true)
                timer.cancel()
            }
        }
    }
}

/// Set once; waiters resume then, or at once if it is already set.
@MainActor
final class SessionSignal {
    private(set) var isSet = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func set() {
        guard !isSet else { return }
        isSet = true
        let waiting = waiters
        waiters = []
        waiting.forEach { $0.resume() }
    }

    func wait() async {
        guard !isSet else { return }
        await withCheckedContinuation { waiters.append($0) }
    }
}

/// Resumes a continuation with whichever result comes first.
private final class FirstOutcome: Sendable {
    private let continuation: Mutex<CheckedContinuation<Bool, Never>?>

    init(_ continuation: CheckedContinuation<Bool, Never>) {
        self.continuation = Mutex(continuation)
    }

    func resume(_ value: Bool) {
        let pending = continuation.withLock { stored in
            defer { stored = nil }
            return stored
        }
        pending?.resume(returning: value)
    }
}
