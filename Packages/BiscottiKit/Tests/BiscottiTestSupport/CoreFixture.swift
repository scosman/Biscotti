import AppCore
import AudioCapture
import Calendar
import DataStore
import Foundation
import Intelligence
import LocalLLM
import MeetingCatalog
import MeetingDetection
import Notifications
import Permissions
import Recording
import TranscriptionService
import UserNotifications

/// Bundles all test dependencies for AppCore-based tests.
///
/// Provides a pre-wired `AppCore` with in-memory storage and configurable
/// fakes. Shared across all UI and integration test targets.
@MainActor
public struct CoreFixture {
    public let core: AppCore
    public let store: DataStore
    public let fakeRecorder: FakeRecorder
    public let fakeEngine: FakeTranscriber
    public let storageRoot: URL
    public let permissions: Permissions
    public let calendarService: CalendarService
    public let fakeEventStore: FakeEventStore
    public let detector: MeetingDetector
    public let notificationService: NotificationService
    public let fakeNotificationCenter: FakeTestNotificationCenter
    public let fakeActivitySource: FakeActivitySource
    public let fakeScheduler: FakeScheduler?
    public let intelligence: Intelligence
    public let fakeLLMRunner: FakeCoreLLMRunner
    public let fakeModelProvider: FakeCoreModelProvider

    public func cleanup() {
        try? FileManager.default.removeItem(at: storageRoot)
    }

    /// Creates a meeting with present audio files and returns its ID.
    ///
    /// - Parameters:
    ///   - title: The meeting title.
    ///   - recordingDuration: Optional wall-clock recording duration (seconds).
    ///     When non-nil, stored via `setRecordingDuration(_:for:)`.
    public func createMeetingWithAudio(
        title: String = "Test Meeting",
        recordingDuration: TimeInterval? = nil
    ) async throws -> UUID {
        let meetingID = try await store.createMeeting(title: title)
        let micRef = AudioFileRef(
            role: .mic,
            path: "/tmp/test/mic.aac",
            byteSize: 1024,
            isPresent: true
        )
        let sysRef = AudioFileRef(
            role: .system,
            path: "/tmp/test/system.aac",
            byteSize: 2048,
            isPresent: true
        )
        try await store.attachAudio([micRef, sysRef], to: meetingID)
        if let recordingDuration {
            try await store.setRecordingDuration(
                recordingDuration, for: meetingID
            )
        }
        return meetingID
    }
}

/// A configurable fake EventStore for tests.
public final class FakeEventStore: EventStoreProviding,
    @unchecked Sendable
{
    public var authStatus: CalendarAuthStatus
    public var requestAccessResult: Bool
    public var calendarInfos: [CalendarInfo]
    public var eventDTOs: [EKEventDTO]
    public var refreshResult: EKEventDTO?

    public init(
        authStatus: CalendarAuthStatus = .authorized,
        requestAccessResult: Bool = true,
        calendarInfos: [CalendarInfo] = [],
        eventDTOs: [EKEventDTO] = [],
        refreshResult: EKEventDTO? = nil
    ) {
        self.authStatus = authStatus
        self.requestAccessResult = requestAccessResult
        self.calendarInfos = calendarInfos
        self.eventDTOs = eventDTOs
        self.refreshResult = refreshResult
    }

    public func authorizationStatus() -> CalendarAuthStatus {
        authStatus
    }

    public func requestAccess() async throws -> Bool {
        requestAccessResult
    }

    public func calendars() -> [CalendarInfo] {
        calendarInfos
    }

    public func events(
        in _: DateInterval, calendars _: [String]?
    ) -> [EKEventDTO] {
        eventDTOs
    }

    public func refreshEvent(
        eventIdentifier _: String, occurrenceStart _: Date
    ) -> EKEventDTO? {
        refreshResult
    }
}

// MARK: - FakeScheduler

/// Controllable scheduler for deterministic timer tests.
///
/// Records `sleep` calls and lets tests advance time explicitly via
/// `advance(by:)` to fire pending sleeps.
@MainActor
public final class FakeScheduler: AppScheduler, @unchecked Sendable {
    private var currentInstant: ContinuousClock.Instant
    private var pendingSleeps: [(
        deadline: ContinuousClock.Instant,
        continuation: CheckedContinuation<Void, any Error>
    )] = []

    public init(
        now: ContinuousClock.Instant = ContinuousClock.now
    ) {
        currentInstant = now
    }

    public func sleep(for duration: Duration) async throws {
        let deadline = currentInstant + duration
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
            pendingSleeps.append(
                (deadline: deadline, continuation: continuation)
            )
        }
    }

    public nonisolated func now() -> ContinuousClock.Instant {
        // Called from nonisolated context; safe because tests run
        // single-threaded on MainActor.
        MainActor.assumeIsolated { currentInstant }
    }

    /// Advance time and resume all sleeps whose deadlines have elapsed.
    public func advance(by duration: Duration) {
        currentInstant += duration
        resumeElapsed()
    }

    /// Resume all sleeps whose deadline <= currentInstant.
    private func resumeElapsed() {
        let elapsed = pendingSleeps.filter {
            $0.deadline <= currentInstant
        }
        pendingSleeps.removeAll { $0.deadline <= currentInstant }
        for entry in elapsed {
            entry.continuation.resume()
        }
    }

    /// Cancel all pending sleeps with CancellationError.
    public func cancelAll() {
        let all = pendingSleeps
        pendingSleeps.removeAll()
        for entry in all {
            entry.continuation.resume(
                throwing: CancellationError()
            )
        }
    }

    /// The number of pending sleep calls.
    public var pendingCount: Int {
        pendingSleeps.count
    }
}

// MARK: - FakeTestNotificationCenter

/// Records notification calls for assertion in tests.
///
/// NOT `@MainActor` — conforms to `NotificationCenterProviding` (which is
/// `Sendable`, nonisolated). All mutable state lives in a reference-type
/// backing store marked `@unchecked Sendable` (safe because all tests run
/// on `@MainActor` single-threaded).
public final class FakeTestNotificationCenter: NotificationCenterProviding,
    @unchecked Sendable
{
    /// Reference-type backing for mutable state.
    public final class Backing: @unchecked Sendable {
        public var authGranted = true
        public var authStatus: UNAuthorizationStatus = .authorized
        public var addedRequests: [UNNotificationRequest] = []
        public var removedPendingIDs: [String] = []
        public var removedDeliveredIDs: [String] = []
        public var registeredCategories: Set<UNNotificationCategory> = []
        public var scriptedAlertStyle: UNAlertStyle = .banner
    }

    public let backing = Backing()

    public init() {}

    public func requestAuthorization() async throws -> Bool {
        backing.authGranted
    }

    public func authorizationStatus() async -> UNAuthorizationStatus {
        backing.authStatus
    }

    public func add(_ request: UNNotificationRequest) async throws {
        backing.addedRequests.append(request)
    }

    public func removePendingRequests(withIdentifiers ids: [String]) {
        backing.removedPendingIDs.append(contentsOf: ids)
    }

    public func removeDeliveredNotifications(
        withIdentifiers ids: [String]
    ) {
        backing.removedDeliveredIDs.append(contentsOf: ids)
    }

    public func setCategories(
        _ categories: Set<UNNotificationCategory>
    ) {
        backing.registeredCategories = categories
    }

    public func alertStyle() async -> UNAlertStyle {
        backing.scriptedAlertStyle
    }

    /// Convenience accessors
    public var addedRequests: [UNNotificationRequest] {
        backing.addedRequests
    }
}

// MARK: - ImmediateClock (for MeetingDetector debounce bypass)

/// A clock that completes `sleep` immediately, making debounce
/// timers fire without real delays. Used to bypass MeetingDetector's
/// 3s/8s debounce in integration tests that drive the full
/// fakeActivitySource -> MeetingDetector -> AppCore pipeline.
public struct ImmediateClock: Clock, Sendable {
    public typealias Duration = Swift.Duration

    public struct Instant: InstantProtocol {
        public var offset: Swift.Duration
        public static var zero: Instant {
            Instant(offset: .zero)
        }

        public func advanced(
            by duration: Swift.Duration
        ) -> Instant {
            Instant(offset: offset + duration)
        }

        public func duration(to other: Instant) -> Swift.Duration {
            other.offset - offset
        }

        public static func < (
            lhs: Instant, rhs: Instant
        ) -> Bool {
            lhs.offset < rhs.offset
        }
    }

    public var now: Instant {
        .zero
    }

    public var minimumResolution: Swift.Duration {
        .zero
    }

    public init() {}

    public func sleep(
        until _: Instant, tolerance _: Swift.Duration?
    ) async throws {
        try Task.checkCancellation()
        await Task.yield()
    }
}

// MARK: - FakeActivitySource

/// Yields scripted AudioProcess snapshots on demand for tests.
///
/// NOT `@MainActor` — conforms to `ActivitySource` (which is `Sendable`,
/// nonisolated). Uses `@unchecked Sendable` (safe because tests run
/// single-threaded on `@MainActor`).
public final class FakeActivitySource: ActivitySource,
    @unchecked Sendable
{
    private var continuation: AsyncStream<[AudioProcess]>.Continuation?

    public init() {}

    public func activityStream() -> AsyncStream<[AudioProcess]> {
        let (stream, cont) = AsyncStream.makeStream(
            of: [AudioProcess].self
        )
        continuation = cont
        return stream
    }

    /// Push a snapshot into the stream for test consumption.
    public func emit(_ processes: [AudioProcess]) {
        continuation?.yield(processes)
    }

    /// Finish the stream.
    public func finish() {
        continuation?.finish()
    }
}

// MARK: - Fake LLM fakes for CoreFixture

/// A simple fake LLM runner for AppCore integration tests.
/// Records session usage; does not return meaningful LLM output.
public final class FakeCoreLLMRunner: LLMRunning, @unchecked Sendable {
    /// Number of times `withSession` was called.
    public var sessionCount = 0

    public init() {}

    public func withSession<T: Sendable>(
        config _: LocalLLM.EngineConfig,
        _ body: @Sendable (any LLMSession) async throws -> T
    ) async throws -> T {
        sessionCount += 1
        return try await body(FakeCoreLLMSession())
    }
}

/// A minimal fake LLM session that returns empty responses.
public struct FakeCoreLLMSession: LLMSession {
    public func countTokens(
        messages _: [LocalLLM.LLMMessage]
    ) async throws -> Int {
        100
    }

    public func reconfigure(contextSize _: Int) async throws {}

    public func generate(
        messages _: [LocalLLM.LLMMessage],
        options _: LocalLLM.GenerationOptions
    ) async throws -> String {
        ""
    }

    public func generateStreaming(
        messages _: [LocalLLM.LLMMessage],
        options _: LocalLLM.GenerationOptions
    ) async -> AsyncThrowingStream<LocalLLM.StreamEvent, Error> {
        AsyncThrowingStream { $0.finish() }
    }
}

/// A fake model provider for AppCore integration tests.
public final class FakeCoreModelProvider: ModelProviding,
    @unchecked Sendable
{
    public var downloaded: Bool
    public let modelURL: URL

    public init(downloaded: Bool = false) {
        self.downloaded = downloaded
        modelURL = URL(fileURLWithPath: "/fake/model.gguf")
    }

    public func isDownloaded() -> Bool {
        downloaded
    }

    public func download(
        progress _: @Sendable @escaping (Int64, Int64?) -> Void
    ) async throws {
        downloaded = true
    }
}

/// Creates a `CoreFixture` with configurable fakes.
@MainActor
// swiftlint:disable:next function_body_length
public func makeCoreFixture(
    micStatus: PermissionState = .authorized,
    micRequestResult: Bool = true,
    startError: (any Error)? = nil,
    probableDenied: Bool = false,
    stateValues: [CaptureState] = [],
    denialCheckDelay: Duration = .seconds(60),
    calendarAuthStatus: CalendarAuthStatus = .authorized,
    calendarInfos: [CalendarInfo] = [],
    calendarEventDTOs: [EKEventDTO] = [],
    calendarRefreshResult: EKEventDTO? = nil,
    calendarAuthorizer: (any CalendarAuthorizing)? = nil,
    notificationAuthorizer: (any NotificationAuthorizing)? = nil,
    useFakeScheduler: Bool = false,
    useImmediateDetectorClock: Bool = false,
    modelDownloaded: Bool = false,
    testName: String = "Test"
) throws -> CoreFixture {
    let store = try DataStore(storage: .inMemory)
    let micAuth = FakeMicAuthorizer(
        status: micStatus, requestResult: micRequestResult
    )
    let permissions = Permissions(
        mic: micAuth,
        cal: calendarAuthorizer,
        notif: notificationAuthorizer,
        systemAudioStore: InMemorySystemAudioPermissionStore()
    )

    let storageRoot = FileManager.default.temporaryDirectory
        .appendingPathComponent("\(testName)-\(UUID().uuidString)")
    try FileManager.default.createDirectory(
        at: storageRoot, withIntermediateDirectories: true
    )

    let fakeRecorder = FakeRecorder(
        startError: startError,
        probableDenied: probableDenied,
        stateValues: stateValues
    )

    let recording = RecordingController(
        store: store,
        permissions: permissions,
        storageRoot: storageRoot,
        makeRecorder: { fakeRecorder },
        denialCheckDelay: denialCheckDelay
    )

    let fakeEngine = FakeTranscriber()
    let transcription = TranscriptionService(
        store: store, engine: fakeEngine
    )

    let fakeEventStore = FakeEventStore(
        authStatus: calendarAuthStatus,
        requestAccessResult: true,
        calendarInfos: calendarInfos,
        eventDTOs: calendarEventDTOs,
        refreshResult: calendarRefreshResult
    )
    let catalog = BundledMeetingCatalog()
    let calendarService = CalendarService(
        store: store,
        catalog: catalog,
        provider: fakeEventStore
    )

    let fakeActivitySource = FakeActivitySource()
    let detector = if useImmediateDetectorClock {
        MeetingDetector(
            catalog: catalog,
            source: fakeActivitySource,
            clock: AnyClock(ImmediateClock())
        )
    } else {
        MeetingDetector(
            catalog: catalog,
            source: fakeActivitySource
        )
    }

    let fakeNotifCenter = FakeTestNotificationCenter()
    let notificationService = NotificationService(
        provider: fakeNotifCenter
    )

    let fakeScheduler: FakeScheduler? = useFakeScheduler
        ? FakeScheduler() : nil
    let scheduler: any AppScheduler = fakeScheduler
        ?? LiveAppScheduler()

    let fakeLLMRunner = FakeCoreLLMRunner()
    let fakeModelProvider = FakeCoreModelProvider(
        downloaded: modelDownloaded
    )
    let intelligence = Intelligence(
        store: store,
        llm: fakeLLMRunner,
        models: fakeModelProvider,
        settings: { AISettings(enabled: true) }
    )

    let core = AppCore(
        store: store,
        permissions: permissions,
        recording: recording,
        transcription: transcription,
        calendar: calendarService,
        detector: detector,
        notifications: notificationService,
        intelligence: intelligence,
        scheduler: scheduler
    )

    return CoreFixture(
        core: core,
        store: store,
        fakeRecorder: fakeRecorder,
        fakeEngine: fakeEngine,
        storageRoot: storageRoot,
        permissions: permissions,
        calendarService: calendarService,
        fakeEventStore: fakeEventStore,
        detector: detector,
        notificationService: notificationService,
        fakeNotificationCenter: fakeNotifCenter,
        fakeActivitySource: fakeActivitySource,
        fakeScheduler: fakeScheduler,
        intelligence: intelligence,
        fakeLLMRunner: fakeLLMRunner,
        fakeModelProvider: fakeModelProvider
    )
}
