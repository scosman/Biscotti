import Foundation
import LiveTranscription
import LiveTranscriptModel
import Observation
import os
import Transcription

/// The live transcript of the recording in progress, the drafts of recordings
/// that just stopped, and the drawer's state. AppCore owns one.
///
/// Each recording gets its own `LiveRecordingSession`; the observable state
/// here mirrors the current one. After Stop, a session finishing in the
/// background writes only to its own meeting's draft.
@MainActor @Observable
public final class LiveTranscriptionService {
    private static let log = Logger(subsystem: "net.scosman.biscotti", category: "live")
    static let drawerExpandedKey = "liveTranscript.drawerExpanded"
    static let drawerHeightKey = "liveTranscript.drawerHeight"

    // MARK: - Observable state

    public private(set) var status: LiveStatus = .off {
        didSet {
            guard status != oldValue else { return }
            let described = String(describing: status)
            Self.log.notice("Live status: \(described, privacy: .public)")
            let visible = status != .off
            if isVisible != visible { isVisible = visible }
            if status == .starting {
                startingSince = Date()
            } else if startingSince != nil {
                startingSince = nil
            }
        }
    }

    /// True while live transcription runs for the current recording,
    /// available or not: the recording screen shows the toggle. Set only when
    /// it changes, so views that need only this do not redraw on every
    /// status change.
    public private(set) var isVisible = false
    /// When the current Starting began. The first start of a new build can
    /// take minutes while macOS compiles the model.
    public private(set) var startingSince: Date?
    /// 0…1, about 12 updates a second while live.
    public private(set) var level: Float = 0
    /// In time order across tracks, tails included.
    public private(set) var rows: [LiveRow] = [] {
        didSet { rowsRevision += 1 }
    }

    /// Counts changes to `rows`. The drawer reports each one it draws
    /// (`rowsDrawn()`), for the latency signposts.
    public private(set) var rowsRevision = 0
    public private(set) var gaps: [LiveGap] = []
    /// Set when live transcription started mid-recording.
    public private(set) var startMarker: TimeInterval?
    public private(set) var language: LiveLanguage
    public private(set) var detectedLanguageName: String?
    /// Persisted, so the drawer opens as it was last left.
    public var isDrawerExpanded: Bool {
        get { drawerExpanded }
        set {
            drawerExpanded = newValue
            defaults?.set(newValue, forKey: Self.drawerExpandedKey)
        }
    }

    private var drawerExpanded: Bool

    /// The height the user dragged the drawer to, persisted across meetings;
    /// nil for the default, which fits the window. The recording screen
    /// keeps it within its limits.
    public var drawerHeight: CGFloat? {
        get { storedDrawerHeight }
        set {
            storedDrawerHeight = newValue
            if let newValue {
                defaults?.set(Double(newValue), forKey: Self.drawerHeightKey)
            } else {
                defaults?.removeObject(forKey: Self.drawerHeightKey)
            }
        }
    }

    private var storedDrawerHeight: CGFloat?

    /// The drawer scrolls to it, then calls `revealRequestHandled(_:)`.
    public private(set) var revealRequest: RevealRequest?
    /// The resolved setting.
    public private(set) var isEnabled: Bool
    public private(set) var modelState: LiveModelState
    /// Called once a download has put the live model on disk. AppCore uses
    /// it to prepare the model before the next recording.
    @ObservationIgnored public var onModelDownloaded: (@MainActor () -> Void)?
    /// Closes the app's other connection to the transcription worker, after
    /// a language change found the worker stuck in a decode. AppCore sets it.
    @ObservationIgnored public var onWorkerNeedsReset: (@MainActor () async -> Void)?
    private var drafts: [UUID: LiveTranscriptSnapshot] = [:]

    // MARK: - Private

    private struct ActiveRecording {
        let meetingID: UUID
        let source: any LiveAudioSource
        let timelineOffset: TimeInterval
        let startedAt: Date

        /// Seconds on the recording timeline now.
        var now: TimeInterval {
            max(0, Date().timeIntervalSince(startedAt) + timelineOffset)
        }
    }

    @ObservationIgnored private let makeEngine: LiveEngineFactory
    @ObservationIgnored private let model: any LiveModelProviding
    @ObservationIgnored private let vocabulary: @Sendable (UUID) async -> [String]
    @ObservationIgnored private let defaults: UserDefaults?
    @ObservationIgnored private let onSettledTextViolation: @Sendable (String) -> Void
    @ObservationIgnored private let macLanguageCode: String?
    @ObservationIgnored private let timing: LiveTiming
    @ObservationIgnored private var power: PowerPolicy?
    @ObservationIgnored private var recording: ActiveRecording?
    @ObservationIgnored private var current: LiveRecordingSession?
    /// Sessions of stopped recordings still finishing, by meeting.
    @ObservationIgnored private var finishing: [UUID: LiveRecordingSession] = [:]
    /// The session allowed to write each meeting's draft, until it is released.
    @ObservationIgnored private var draftWriters: [UUID: ObjectIdentifier] = [:]
    @ObservationIgnored private var download: Task<Void, Never>?
    @ObservationIgnored private var downloadToken = UUID()

    /// - Parameters:
    ///   - engine: Makes one engine session per generation.
    ///   - model: The live engine's model on disk.
    ///   - vocabulary: The effective vocabulary of a meeting.
    ///   - isEnabled: The resolved setting at launch.
    ///   - defaults: Keeps the drawer's state; nil keeps it in memory only.
    ///   - macLanguageCode: The Mac's language; English makes English the
    ///     default, anything else Detect.
    ///   - onSettledTextViolation: Hears about settled text that changed,
    ///     after it is logged; tests stop on it.
    public init(
        engine: @escaping LiveEngineFactory,
        model: any LiveModelProviding,
        vocabulary: @escaping @Sendable (UUID) async -> [String],
        isEnabled: Bool,
        power: any PowerStateProviding = SystemPowerState(),
        defaults: UserDefaults? = .standard,
        macLanguageCode: String? = Locale.preferredLanguages.first.flatMap { Locale(identifier: $0).language.languageCode?.identifier },
        timing: LiveTiming = LiveTiming(),
        onSettledTextViolation: @escaping @Sendable (String) -> Void = { _ in }
    ) {
        makeEngine = engine
        self.model = model
        self.vocabulary = vocabulary
        self.isEnabled = isEnabled
        self.defaults = defaults
        self.macLanguageCode = macLanguageCode
        self.timing = timing
        self.onSettledTextViolation = onSettledTextViolation
        language = Self.defaultLanguage(macLanguageCode: macLanguageCode)
        drawerExpanded = defaults?.bool(forKey: Self.drawerExpandedKey) ?? false
        storedDrawerHeight = (defaults?.object(forKey: Self.drawerHeightKey) as? Double).map { CGFloat($0) }
        modelState = model.isPresent() ? .ready : .missing
        self.power = PowerPolicy(source: power) { [weak self] decision in
            Task { await self?.current?.applyPower(decision) }
        }
    }

    /// The language menu's default: English on a Mac in English, otherwise Detect.
    static func defaultLanguage(macLanguageCode: String?) -> LiveLanguage {
        macLanguageCode == "en" ? .english : .detect
    }

    /// Whether a recording started now would get a live session: the setting
    /// is on and the model is on disk.
    public var canStartLive: Bool {
        isEnabled && model.isPresent()
    }

    // MARK: - Recording lifecycle

    /// A recording started. Cancels the finishing work of earlier recordings;
    /// their drafts keep what they have. Returns once the session is set up;
    /// the engine starts in the background.
    ///
    /// - Parameters:
    ///   - tap: The recording's live tap, attached whether or not live
    ///     transcription is on, so turning it on mid-recording can start.
    ///   - timelineOffset: `RecordingState.timelineOffset`.
    ///   - recordingStartedAt: When capture started, to place a start
    ///     mid-recording on the timeline.
    public func start(
        meetingID: UUID,
        tap: any LiveAudioSource,
        timelineOffset: TimeInterval,
        recordingStartedAt: Date = Date()
    ) async {
        // The recording is known before the first wait, so a Stop that comes
        // meanwhile finds it and no session starts after it.
        let earlier = current
        current = nil
        recording = ActiveRecording(meetingID: meetingID, source: tap, timelineOffset: timelineOffset, startedAt: recordingStartedAt)
        resetLiveState()
        language = Self.defaultLanguage(macLanguageCode: macLanguageCode)
        await cancelFinishingSessions()
        await earlier?.cancel()
        guard isEnabled, recording?.meetingID == meetingID else { return }
        await startSession(from: 0, marker: nil)
    }

    /// The recording stopped. Publishes the meeting's draft at once and
    /// detaches its session, which finishes in the returned task under the
    /// stop deadline and adds its last words to that draft only.
    ///
    /// The spec's task returns nothing. It returns how the finish ended,
    /// because after a time-out AppCore must release the worker, which may be
    /// stuck in a decode.
    public func stop(_ meetingID: UUID) -> Task<LiveFinishResult, Never> {
        guard recording?.meetingID == meetingID else { return Task { .nothingToFinish } }
        recording = nil
        guard let session = current else {
            resetLiveState()
            return Task { .nothingToFinish }
        }
        current = nil
        resetLiveState()
        draftWriters[meetingID] = ObjectIdentifier(session)
        writeDraft(from: session)
        finishing[meetingID] = session
        return Task { @MainActor [weak self] in
            let result = await session.finish()
            guard let self else { return result }
            if finishing[meetingID] === session { finishing[meetingID] = nil }
            writeDraft(from: session)
            Self.log.notice("Live finish after Stop: \(String(describing: result), privacy: .public)")
            return result
        }
    }

    /// From Settings. During a recording, off ends live transcription and
    /// clears its state; on starts it from now, with a start marker.
    public func setEnabled(_ enabled: Bool) async {
        guard enabled != isEnabled else { return }
        isEnabled = enabled
        guard let recording else { return }
        if enabled {
            let now = recording.now
            await startSession(from: now, marker: now)
        } else {
            let session = current
            current = nil
            resetLiveState()
            await session?.cancel()
        }
    }

    /// Applies from now on.
    public func setLanguage(_ language: LiveLanguage) async {
        guard language != self.language else { return }
        self.language = language
        detectedLanguageName = nil
        guard language.isSupportedByWhisper else {
            let session = current
            current = nil
            resetLiveState()
            if recording != nil, isEnabled { status = .unavailable(.languageUnsupported) }
            await session?.cancel()
            return
        }
        if let current {
            await current.switchLanguage(to: language)
        } else if let recording, isEnabled, status == .unavailable(.languageUnsupported) {
            let now = recording.now
            await startSession(from: now, marker: now)
        }
    }

    // MARK: - Private

    private func startSession(from startTime: TimeInterval, marker: TimeInterval?) async {
        guard let recording else { return }
        guard model.isPresent() else {
            modelState = .missing
            status = .unavailable(.modelMissing)
            return
        }
        guard language.isSupportedByWhisper else {
            status = .unavailable(.languageUnsupported)
            return
        }
        let words = await vocabulary(recording.meetingID)
        // The recording may have stopped, or the setting changed, meanwhile.
        guard self.recording?.meetingID == recording.meetingID, isEnabled, current == nil else { return }
        let session = LiveRecordingSession(setup: LiveSessionSetup(
            meetingID: recording.meetingID,
            source: recording.source,
            makeEngine: makeEngine,
            vocabulary: words,
            language: language,
            startTime: startTime,
            timing: timing,
            power: power?.decision ?? PowerPolicy.Decision(PowerState()),
            onSettledTextViolation: onSettledTextViolation,
            resetWorker: { [weak self] in await self?.onWorkerNeedsReset?() }
        ))
        session.onChange = { [weak self] in self?.sessionDidChange($0) }
        session.onLevel = { [weak self, weak session] level in
            guard let self, let session, session === current else { return }
            self.level = level
        }
        current = session
        startMarker = marker
        status = .starting
        Self.log.notice("Live transcription starting\(marker == nil ? "" : " mid-recording", privacy: .public)")
        session.begin()
    }

    private func sessionDidChange(_ session: LiveRecordingSession) {
        if session === current {
            // Unchanged values are not assigned, so views do not redraw for nothing.
            let store = session.store
            if rows != store.rows { rows = store.rows }
            if gaps != store.gaps { gaps = store.gaps }
            if status != session.status { status = session.status }
            let name = store.detectedLanguage.flatMap { Locale.current.localizedString(forLanguageCode: $0) }
            if detectedLanguageName != name { detectedLanguageName = name }
            // The engine found the model missing although the disk check passed.
            if session.unavailableReason == .modelMissing, modelState == .ready { modelState = .missing }
        } else {
            writeDraft(from: session)
        }
    }

    /// A stopped recording's session writes its meeting's draft while it may.
    /// A draft without text is not kept.
    private func writeDraft(from session: LiveRecordingSession) {
        guard draftWriters[session.meetingID] == ObjectIdentifier(session) else { return }
        let draft = session.store.snapshot(includeTail: true)
        drafts[session.meetingID] = draft.rows.isEmpty ? nil : draft
    }

    private func cancelFinishingSessions() async {
        let sessions = Array(finishing.values)
        finishing = [:]
        for session in sessions {
            await session.cancel()
        }
    }

    private func resetLiveState() {
        status = .off
        level = 0
        rows = []
        gaps = []
        startMarker = nil
        detectedLanguageName = nil
        revealRequest = nil
    }
}

// MARK: - Model

extension LiveTranscriptionService {
    /// Downloads the live model. During a recording with live transcription
    /// on, live transcription starts from the moment it is on disk.
    ///
    /// Onboarding, the drawer's "model needed" state and Settings call it.
    ///
    /// A call while a download runs waits for that download.
    public func downloadModel() async {
        if let download {
            await download.value
            return
        }
        let task = Task { await runDownload() }
        download = task
        await task.value
        download = nil
    }

    private func runDownload() async {
        let token = UUID()
        downloadToken = token
        modelState = .downloading("Preparing\u{2026}")
        do {
            try await model.download { [weak self] message in
                Task { @MainActor [weak self] in
                    guard let self, downloadToken == token, case .downloading = modelState else { return }
                    modelState = .downloading(message)
                }
            }
        } catch {
            modelState = .failed(error.localizedDescription)
            return
        }
        downloadToken = UUID()
        modelState = model.isPresent() ? .ready : .failed("The live transcript model is incomplete.")
        if modelState == .ready { onModelDownloaded?() }
        guard modelState == .ready, let recording, isEnabled, status == .unavailable(.modelMissing) else { return }
        // A session whose engine found no model has ended; a new one takes over.
        if current?.unavailableReason == .modelMissing { current = nil }
        let now = recording.now
        await startSession(from: now, marker: now)
    }
}

// MARK: - Drawer and reading

extension LiveTranscriptionService {
    /// The current recording's in-app latency figures.
    var currentLatency: LiveLatency? {
        current?.latency
    }
}

public extension LiveTranscriptionService {
    func toggleDrawer() {
        isDrawerExpanded.toggle()
    }

    /// Opens the drawer at a moment of the recording.
    func reveal(atRecordingTime time: TimeInterval) {
        revealRequest = RevealRequest(time: time)
        isDrawerExpanded = true
    }

    func revealRequestHandled(_ request: RevealRequest) {
        if revealRequest == request { revealRequest = nil }
    }

    /// The drawer drew the rows of the latest `rowsRevision`; ends the
    /// current recording's latency intervals.
    func rowsDrawn() {
        currentLatency?.rowsDrawn()
    }

    /// A frozen copy of the current recording's live transcript.
    func snapshot(includeTail: Bool) -> LiveTranscriptSnapshot? {
        current?.store.snapshot(includeTail: includeTail)
    }

    /// The live text of a stopped recording, until its final transcript is saved.
    func draft(for meetingID: UUID) -> LiveTranscriptSnapshot? {
        drafts[meetingID]
    }

    /// Whether a stopped recording's live session is still finishing its
    /// last words.
    func isFinishing(_ meetingID: UUID) -> Bool {
        finishing[meetingID] != nil
    }

    /// The final transcript replaced the draft, or the meeting was deleted.
    /// AppCore calls this once
    /// `TranscriptionService` reports the job `.completed` (the spec has the
    /// service watch the job; this module does not depend on
    /// `TranscriptionService`). A failed pass keeps the draft.
    func releaseDraft(for meetingID: UUID) {
        drafts[meetingID] = nil
        draftWriters[meetingID] = nil
    }
}

public extension LiveTranscriptionService {
    /// A service with no engine and no model, for previews and tests that do
    /// not exercise live transcription: every start is unavailable.
    static func inert() -> LiveTranscriptionService {
        LiveTranscriptionService(
            engine: { InertEngine() },
            model: NoLiveModel(),
            vocabulary: { _ in [] },
            isEnabled: false,
            power: ConstantPowerState(),
            defaults: nil
        )
    }
}

private struct NoLiveModel: LiveModelProviding {
    func isPresent() -> Bool {
        false
    }

    func download(status _: @escaping @Sendable (String) -> Void) async throws {
        throw TranscriptionError.workerUnavailable
    }
}

private struct ConstantPowerState: PowerStateProviding {
    let current = PowerState()

    func changes() -> AsyncStream<PowerState> {
        AsyncStream { $0.finish() }
    }
}

private actor InertEngine: LiveEngineSession {
    nonisolated let updates = AsyncStream<LiveTrackUpdate> { $0.finish() }

    func start(_: LiveSessionConfig) async throws {
        throw TranscriptionError.workerUnavailable
    }

    func offer(_: LiveAudioChunk) async -> Bool {
        false
    }

    func append(_: LiveAudioChunk) async {}
    func setUpdateInterval(_: TimeInterval) async {}
    func setPaused(_: Bool) async {}
    func finish(timeout _: Duration) async -> [LiveTrackUpdate] {
        []
    }

    func cancel() async {}
}
