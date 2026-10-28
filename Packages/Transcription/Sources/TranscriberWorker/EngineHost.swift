import Foundation
import LiveTranscription
import LiveTranscriptModel
import os.log
import Transcription

/// The worker process's one transcription engine and its one live session.
///
/// Every connection's `TranscriberService` hands its calls here, so Whisper
/// is loaded once per process and the final pass and the live session never
/// run at the same time. The app's job queue keeps them apart; the checks
/// here are the guard.
public actor EngineHost {
    /// The host of the transcription worker's process. `onStuckDecode` ends
    /// the process, so the app's connections are interrupted and its next
    /// call starts a fresh worker; the worker's `main` passes it.
    public static func workerProcessHost(onStuckDecode: @escaping @Sendable () -> Void) -> EngineHost {
        EngineHost(onStuckDecode: onStuckDecode)
    }

    enum Activity {
        case idle
        case finalPass(FinalPass)
        /// Loading the live model and starting this owner's session.
        case startingLive(owner: ObjectIdentifier, sessionID: UUID)
        case live(HostedLiveSession)
        /// Finishing or cancelling the session, waiting for its last decode
        /// and unloading its model. A cancel cuts a finish short.
        case endingLive(HostedLiveSession)
        /// Loading and unloading models so macOS compiles them ahead of a meeting.
        case preparing(Preparation)
    }

    /// Models being loaded once and unloaded, so the first meeting after an
    /// update does not wait while macOS compiles them for the Neural Engine.
    /// Its task returns the host to idle when it ends.
    public struct Preparation: Sendable {
        let id: UUID
        let owner: ObjectIdentifier
        let task: Task<[String], Never>

        /// The models prepared, once the preparation ends.
        public var prepared: [String] {
            get async {
                await task.value
            }
        }

        /// Stops after the model loading at the time.
        func cancel() {
            task.cancel()
        }
    }

    /// A running final pass. Its task returns the host to idle when it ends.
    public struct FinalPass: Sendable {
        let id: UUID
        let task: Task<TranscriptResult, any Error>

        /// Waits for the pass to end.
        public var result: TranscriptResult {
            get async throws {
                try await task.value
            }
        }

        /// Stops the pass; it ends with `TranscriptionError.cancelled`.
        func cancel() {
            task.cancel()
        }
    }

    struct HostedLiveSession {
        let config: LiveSessionConfig
        let session: any LiveTranscriptionSession
        let decoder: TrackedLiveDecoder
        /// Set when the live model differs from the final pass's.
        let separateModel: LoadedLiveModel?
        let relay: LiveUpdateRelay
        let owner: any LiveSessionOwner
        var forwarder: Task<Void, Never>?

        func matches(_ sessionID: UUID, _ generation: Int? = nil) -> Bool {
            config.sessionID == sessionID && (generation.map { $0 == config.generation } ?? true)
        }
    }

    struct ResidentModel {
        let name: String
        let model: LoadedLiveModel
    }

    static let log = Logger(subsystem: "net.scosman.biscotti", category: "live")

    /// A live decode that has not returned this long after its session ended
    /// is stuck. The model it uses must not be unloaded or used for other
    /// work while it runs, so only ending the process frees the worker.
    static let stuckDecodeLimit = LiveWorkerLimits.stuckDecode

    private let engine: any HostedTranscriptionEngine
    private let liveModels: any LiveModelLoading
    private let modelIsPresent: @Sendable (String) -> Bool
    private let makeSession: @Sendable (any LiveDecoder) -> any LiveTranscriptionSession
    private let clock: HostClock
    /// Called when a decode is stuck (`stuckDecodeLimit`); the worker
    /// process's host ends the process.
    private let onStuckDecode: @Sendable () -> Void

    /// A live model kept loaded while the live transcript is on, through
    /// live sessions, final passes and preparations, so a recording's live
    /// start needs no load. Replaced by another kept model or a live session
    /// on another model; released when the process exits.
    private(set) var resident: ResidentModel?

    private(set) var activity = Activity.idle {
        didSet {
            let waiters = activityWaiters
            activityWaiters = []
            waiters.forEach { $0.resume() }
        }
    }

    private var activityWaiters: [CheckedContinuation<Void, Never>] = []
    /// Set by a cancel or a closed connection while a session starts.
    private(set) var startIsCancelled = false
    /// Counts `cancelActiveWork` calls, so a pass that waited through one
    /// does not start after the worker has replied idle.
    private var cancelCount = 0

    /// - Parameter modelIsPresent: Whether a Whisper model and its tokenizer
    ///   are in the model cache, so loading it downloads nothing.
    init(
        engine: any HostedTranscriptionEngine = InProcessTranscriptionEngine(),
        liveModels: any LiveModelLoading = LocalWhisperModelLoader(),
        modelIsPresent: @escaping @Sendable (String) -> Bool = { WhisperModelFiles.isPresent(model: $0) },
        makeSession: @escaping @Sendable (any LiveDecoder) -> any LiveTranscriptionSession = { WhisperLiveSession(decoder: $0) },
        clock: some Clock<Duration> = ContinuousClock(),
        onStuckDecode: @escaping @Sendable () -> Void = {}
    ) {
        self.engine = engine
        self.liveModels = liveModels
        self.modelIsPresent = modelIsPresent
        self.makeSession = makeSession
        self.clock = HostClock(clock)
        self.onStuckDecode = onStuckDecode
    }

    var isIdle: Bool {
        if case .idle = activity { true } else { false }
    }

    /// Calls waiting for the activity to change. Tests use it to know a call is waiting.
    var waiterCount: Int {
        activityWaiters.count
    }

    // MARK: - Final pass

    /// Admits a final pass and starts it, after a live session that is ending
    /// has ended. Admission returns at once; await `FinalPass.result` for the
    /// transcript. The XPC service admits passes in order with
    /// `cancelActiveWork`, so a cancel sent after a pass always stops it.
    /// - Throws: `TranscriptionError.workerBusy` while a live session or
    ///   another final pass runs; `.cancelled` when a cancel came while it
    ///   waited for a live session to end.
    /// - Parameter onModelLoad: Told when the pass starts and ends a model load.
    public func startFinalPass(
        micPath: String,
        systemPath: String,
        customVocabulary: [String],
        onModelLoad: (@Sendable (Bool) -> Void)? = nil
    ) async throws -> FinalPass {
        let cancelsBefore = cancelCount
        await waitWhileEnding()
        guard cancelCount == cancelsBefore else { throw TranscriptionError.cancelled }
        guard isIdle else { throw TranscriptionError.workerBusy }
        let id = UUID()
        let engine = engine
        // The task ends the pass itself, so the host returns to idle even if
        // nobody awaits the result. It runs on this actor, after this call
        // has recorded the pass.
        let task = Task {
            await engine.observeModelLoads(onModelLoad)
            let outcome: Result<TranscriptResult, any Error>
            do {
                outcome = try await .success(engine.processAudio(micPath: micPath, systemPath: systemPath, customVocabulary: customVocabulary))
            } catch {
                outcome = .failure(error)
            }
            await engine.observeModelLoads(nil)
            endFinalPass(id)
            return try outcome.get()
        }
        let pass = FinalPass(id: id, task: task)
        activity = .finalPass(pass)
        return pass
    }

    /// Runs a final pass to its end; see `startFinalPass`.
    public func processAudio(micPath: String, systemPath: String, customVocabulary: [String]) async throws -> TranscriptResult {
        try await startFinalPass(micPath: micPath, systemPath: systemPath, customVocabulary: customVocabulary).result
    }

    public func ensureModelsDownloaded(status: @escaping @Sendable (String) -> Void) async throws {
        try await engine.ensureModelsDownloaded(status: status)
    }

    /// Unloads the final pass's models when nothing is using them. Every
    /// connection shares the one engine, so an unload from one connection
    /// must not pull the model from under another's pass or live session.
    public func unloadModels() async {
        guard isIdle else {
            Self.log.notice("Kept the transcription models loaded: they are in use")
            return
        }
        await engine.unloadModels()
    }

    // MARK: - Admission

    /// Returns once the host is idle, without stopping anything. The app's
    /// queue waits here after a pass was refused as `workerBusy`.
    public func waitUntilIdle() async {
        await waitWhile { if case .idle = $0 { false } else { true } }
    }

    /// Cuts a finishing live session short, at once. `cancelActiveWork` does
    /// it too, but it waits its turn behind passes admitted before it. A pass
    /// waiting for this session to end was sent before the cancel, so it is
    /// refused as cancelled rather than started.
    public func cutEndingSessionShort() async {
        guard case let .endingLive(hosted) = activity else { return }
        cancelCount += 1
        await hosted.session.cancel()
    }

    /// Stops a final pass or ends the live session, cutting a finish short,
    /// and returns once the host is idle. A new recording calls it before its
    /// live session starts.
    public func cancelActiveWork() async {
        cancelCount += 1
        while true {
            switch activity {
            case .idle:
                return
            case let .finalPass(pass):
                Self.log.notice("Cancelling the running final pass")
                pass.task.cancel()
                await waitWhile { if case let .finalPass(running) = $0 { running.id == pass.id } else { false } }
            case .startingLive:
                startIsCancelled = true
                await waitWhileStarting()
            case let .live(hosted):
                Self.log.notice("Ending the live session to make room for other work")
                await end(hosted, cancellingSession: true, tellingOwner: true)
            case let .endingLive(hosted):
                // Cuts a finish short; once the session has ended it is a no-op.
                await hosted.session.cancel()
                await waitWhileEnding()
            case let .preparing(preparation):
                Self.log.notice("Cancelling the model preparation")
                preparation.cancel()
                await waitWhile { if case let .preparing(running) = $0 { running.id == preparation.id } else { false } }
            }
        }
    }

    // MARK: - Live session

    /// Starts a live session for `owner`, loading its model first.
    /// A config without `whisperModel` runs on the final pass's model.
    /// - Throws: `TranscriptionError.workerBusy` during a final pass or another
    ///   session, `.needsDownload` when the live model is missing, `.cancelled`
    ///   when a cancel or the owner's disconnect stopped the start.
    public func startLiveSession(_ config: LiveSessionConfig, owner: any LiveSessionOwner) async throws {
        await waitWhileEnding()
        guard isIdle else { throw TranscriptionError.workerBusy }
        activity = .startingLive(owner: ObjectIdentifier(owner), sessionID: config.sessionID)
        startIsCancelled = false
        var hosted: HostedLiveSession
        do {
            hosted = try await prepareSession(config, owner: owner)
        } catch {
            activity = .idle
            throw error
        }
        guard !startIsCancelled else {
            await end(hosted, cancellingSession: true, tellingOwner: false)
            throw TranscriptionError.cancelled
        }
        hosted.forwarder = forwardUpdates(of: hosted)
        activity = .live(hosted)
        let source = Self.modelSource(of: hosted, resident: resident)
        Self.log.notice("Live session started on \(source, privacy: .public)")
    }

    public func appendLiveAudio(sessionID: UUID, generation: Int, chunk: LiveAudioChunk) async {
        guard case let .live(hosted) = activity, hosted.matches(sessionID, generation) else { return }
        await hosted.session.append(chunk)
    }

    public func setLiveUpdateInterval(sessionID: UUID, seconds: TimeInterval) async {
        guard case let .live(hosted) = activity, hosted.matches(sessionID) else { return }
        await hosted.session.setUpdateInterval(seconds)
    }

    public func setLivePaused(sessionID: UUID, paused: Bool) async {
        guard case let .live(hosted) = activity, hosted.matches(sessionID) else { return }
        await hosted.session.setPaused(paused)
    }

    /// Finishes the session and returns its final updates once the host is
    /// idle, so a final pass sent after the reply never finds it busy. A
    /// cancel during the finish ends it early, with no final updates.
    public func finishLiveSession(sessionID: UUID, timeout: Duration) async -> [LiveTrackUpdate] {
        guard case let .live(hosted) = activity, hosted.matches(sessionID) else {
            await waitWhileEnding()
            return []
        }
        activity = .endingLive(hosted)
        let final = await hosted.session.finish(timeout: timeout)
        await finishEnding(hosted, waitingForForwarder: true, tellingOwner: false)
        return final
    }

    /// Ends the session without finishing it, also while it starts or
    /// finishes, and returns once the host is idle.
    public func cancelLiveSession(sessionID: UUID) async {
        switch activity {
        case let .startingLive(_, starting) where starting == sessionID:
            startIsCancelled = true
            await waitWhileStarting()
            await waitWhileEnding()
        case let .live(hosted) where hosted.matches(sessionID):
            await end(hosted, cancellingSession: true, tellingOwner: false)
        case let .endingLive(hosted) where hosted.matches(sessionID):
            await hosted.session.cancel()
            await waitWhileEnding()
        default:
            await waitWhileEnding()
        }
    }

    /// A connection closed: its live session, or the start of one, ends.
    public func ownerDidDisconnect(_ owner: any LiveSessionOwner) async {
        switch activity {
        case let .startingLive(starter, _) where starter == ObjectIdentifier(owner):
            startIsCancelled = true
        case let .live(hosted) where hosted.owner === owner:
            Self.log.notice("Ending the live session of a closed connection")
            await end(hosted, cancellingSession: true, tellingOwner: false)
        case let .endingLive(hosted) where hosted.owner === owner:
            await hosted.session.cancel()
        case let .preparing(preparation) where preparation.owner == ObjectIdentifier(owner):
            preparation.cancel()
        default:
            break
        }
    }
}

// MARK: - Model preparation

extension EngineHost {
    /// Admits a preparation of `models`, in order, and starts it. Admission
    /// returns at once; await `Preparation.prepared` for the models prepared.
    /// The XPC service admits it in order with `cancelActiveWork`, like a
    /// final pass, so a cancel sent after it always stops it.
    /// - Throws: `TranscriptionError.workerBusy` unless the host is idle;
    ///   `.cancelled` when a cancel came while it waited for a live session to end.
    public func startPreparation(
        models: [String],
        keepLoaded: String? = nil,
        reloadingKept: Bool = false,
        owner: any LiveSessionOwner
    ) async throws -> Preparation {
        let cancelsBefore = cancelCount
        await waitWhileEnding()
        guard cancelCount == cancelsBefore else { throw TranscriptionError.cancelled }
        guard isIdle else { throw TranscriptionError.workerBusy }
        let id = UUID()
        // Runs on this actor after this call has recorded the preparation,
        // and returns the host to idle itself.
        let task = Task {
            let prepared = await prepare(models, keepLoaded: keepLoaded, reloadingKept: reloadingKept)
            endPreparation(id)
            return prepared
        }
        let preparation = Preparation(id: id, owner: ObjectIdentifier(owner), task: task)
        activity = .preparing(preparation)
        return preparation
    }

    /// Loads each model on disk and unloads it at once, except `keepLoaded`,
    /// which becomes the resident live model and stays loaded alongside
    /// anything else (the user chose this on 25 October 2026: about 0.3 GB
    /// next to the final pass's models). A model already resident counts as
    /// prepared, unless `reloadingKept` asks for its new files. A model that
    /// fails to load is left for the next preparation; a cancel stops before
    /// the next model.
    private func prepare(_ models: [String], keepLoaded: String?, reloadingKept: Bool) async -> [String] {
        // A pass that just ran in this process may have left its models loaded.
        await engine.unloadModels()
        var prepared: [String] = []
        for model in models {
            guard !Task.isCancelled else { break }
            let isKept = model == keepLoaded
            if resident?.name == model, !(reloadingKept && isKept) {
                prepared.append(model)
                continue
            }
            guard modelIsPresent(model) else {
                Self.log.notice("Not preparing \(model, privacy: .public): it is not on this Mac")
                continue
            }
            if isKept {
                // The new resident replaces the old one, or its old files.
                await releaseResidentModel()
            }
            let started = ContinuousClock.now
            do {
                let loaded = try await liveModels.load(model: model)
                if isKept {
                    resident = ResidentModel(name: model, model: loaded)
                    WorkerMemory.log("after loading the live model to keep it")
                } else {
                    await loaded.unload()
                }
            } catch {
                Self.log.error("Preparing \(model, privacy: .public) failed: \(error.localizedDescription, privacy: .public)")
                continue
            }
            let seconds = Double(started.duration(to: .now).components.seconds)
            Self.log.notice("Prepared \(model, privacy: .public) in \(seconds, privacy: .public) s")
            prepared.append(model)
        }
        return prepared
    }

    private func releaseResidentModel() async {
        guard let resident else { return }
        self.resident = nil
        await resident.model.unload()
        WorkerMemory.log("after unloading the resident live model")
    }
}

// MARK: - Live session lifecycle

extension EngineHost {
    static func modelSource(of hosted: HostedLiveSession, resident: ResidentModel?) -> String {
        if hosted.separateModel != nil { return "a separate model" }
        if let resident, resident.name == hosted.config.whisperModel { return "the model kept loaded" }
        return "the final pass's model"
    }

    private func prepareSession(_ config: LiveSessionConfig, owner: any LiveSessionOwner) async throws -> HostedLiveSession {
        let separateModel: LoadedLiveModel?
        let model: any LiveDecoder
        if let resident, resident.name == config.whisperModel {
            // Kept loaded for this: the session neither loads nor unloads it.
            // A pass just cancelled for this recording may have left the
            // final pass's models loaded.
            await engine.unloadModels()
            separateModel = nil
            model = resident.model.decoder
        } else {
            separateModel = try await loadSeparateModelIfNeeded(config)
            model = if let separateModel {
                separateModel.decoder
            } else {
                try await engine.sharedLiveDecoder()
            }
        }
        let decoder = TrackedLiveDecoder(model)
        let session = makeSession(decoder)
        do {
            try await session.start(config)
        } catch {
            await separateModel?.unload()
            throw error
        }
        let relay = LiveUpdateRelay(clock: clock) { owner.deliver($0) }
        return HostedLiveSession(config: config, session: session, decoder: decoder, separateModel: separateModel, relay: relay, owner: owner)
    }

    /// Loads the live model when it differs from the final pass's. The final
    /// pass's models are unloaded first, so two Whisper models are never
    /// loaded together (they may still be loaded from a pass that was just
    /// cancelled for this recording).
    private func loadSeparateModelIfNeeded(_ config: LiveSessionConfig) async throws -> LoadedLiveModel? {
        guard let model = config.whisperModel, model != engine.whisperModel else { return nil }
        await engine.unloadModels()
        await releaseResidentModel()
        let loaded = try await liveModels.load(model: model)
        WorkerMemory.log("after loading the live model")
        return loaded
    }

    /// Relays the session's updates. A stream that ends while the session is
    /// still live means the engine failed.
    private func forwardUpdates(of hosted: HostedLiveSession) -> Task<Void, Never> {
        let session = hosted.session
        let relay = hosted.relay
        let sessionID = hosted.config.sessionID
        let generation = hosted.config.generation
        return Task(priority: .userInitiated) {
            for await update in session.updates {
                await relay.receive(update)
            }
            await self.updatesEnded(sessionID: sessionID, generation: generation)
        }
    }

    private func updatesEnded(sessionID: UUID, generation: Int) async {
        guard case let .live(hosted) = activity, hosted.matches(sessionID, generation) else { return }
        Self.log.error("The live session ended on its own; telling its connection")
        activity = .endingLive(hosted)
        // Called from the forwarder itself, so it must not wait for it.
        await finishEnding(hosted, waitingForForwarder: false, tellingOwner: true)
    }

    private func end(_ hosted: HostedLiveSession, cancellingSession: Bool, tellingOwner: Bool) async {
        activity = .endingLive(hosted)
        if cancellingSession {
            await hosted.session.cancel()
        }
        await finishEnding(hosted, waitingForForwarder: true, tellingOwner: tellingOwner)
    }

    /// Sends what is pending, waits for the last decode to return, releases a
    /// separate model and becomes idle. Runs while the activity is `.endingLive`.
    private func finishEnding(_ hosted: HostedLiveSession, waitingForForwarder: Bool, tellingOwner: Bool) async {
        if waitingForForwarder {
            await hosted.forwarder?.value
        }
        await hosted.relay.flush()
        await waitForLastDecode(of: hosted)
        if let model = hosted.separateModel {
            await model.unload()
            WorkerMemory.log("after unloading the live model")
        }
        if tellingOwner {
            hosted.owner.sessionDidEnd(sessionID: hosted.config.sessionID, generation: hosted.config.generation)
        }
        activity = .idle
        Self.log.notice("Live session ended")
    }

    /// Waits for the session's last decode to return before its model is
    /// unloaded or other work starts. One still out after `stuckDecodeLimit`
    /// is stuck: the host reports it, and the worker's process ends.
    private func waitForLastDecode(of hosted: HostedLiveSession) async {
        let decoder = hosted.decoder
        let returned = await clock.finishes(within: Self.stuckDecodeLimit) { await decoder.waitUntilIdle() }
        guard !returned else { return }
        Self.log.fault("A live decode has not returned \(Self.stuckDecodeLimit, privacy: .public) after its session ended; the worker ends so the app starts a fresh one")
        onStuckDecode()
        await decoder.waitUntilIdle()
    }

    private func endFinalPass(_ id: UUID) {
        guard case let .finalPass(running) = activity, running.id == id else { return }
        activity = .idle
    }

    private func endPreparation(_ id: UUID) {
        guard case let .preparing(running) = activity, running.id == id else { return }
        activity = .idle
    }

    private func waitWhileEnding() async {
        await waitWhile { if case .endingLive = $0 { true } else { false } }
    }

    private func waitWhileStarting() async {
        await waitWhile { if case .startingLive = $0 { true } else { false } }
    }

    private func waitWhile(_ condition: (Activity) -> Bool) async {
        while condition(activity) {
            await withCheckedContinuation { activityWaiters.append($0) }
        }
    }
}
