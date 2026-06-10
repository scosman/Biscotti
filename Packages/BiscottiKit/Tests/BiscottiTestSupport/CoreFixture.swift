import AppCore
import AudioCapture
import Calendar
import DataStore
import Foundation
import MeetingCatalog
import Permissions
import Recording
import TranscriptionService

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

    public func cleanup() {
        try? FileManager.default.removeItem(at: storageRoot)
    }

    /// Creates a meeting with present audio files and returns its ID.
    public func createMeetingWithAudio(title: String = "Test Meeting") async throws -> UUID {
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
        return meetingID
    }
}

/// A configurable fake EventStore for tests.
public final class FakeEventStore: EventStoreProviding, @unchecked Sendable {
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

/// Creates a `CoreFixture` with configurable fakes.
@MainActor
// swiftlint:disable:next function_body_length
public func makeCoreFixture(
    micStatus: PermissionState = .authorized,
    micRequestResult: Bool = true,
    startError: (any Error)? = nil,
    probableDenied: Bool = false,
    stateValues: [CaptureState] = [],
    summaryLimit: Int = 50,
    denialCheckDelay: Duration = .seconds(60),
    calendarAuthStatus: CalendarAuthStatus = .authorized,
    calendarInfos: [CalendarInfo] = [],
    calendarEventDTOs: [EKEventDTO] = [],
    calendarRefreshResult: EKEventDTO? = nil,
    testName: String = "Test"
) throws -> CoreFixture {
    let store = try DataStore(storage: .inMemory)
    let micAuth = FakeMicAuthorizer(
        status: micStatus, requestResult: micRequestResult
    )
    let permissions = Permissions(mic: micAuth)

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
    let transcription = TranscriptionService(store: store, engine: fakeEngine)

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

    let core = AppCore(
        store: store,
        permissions: permissions,
        recording: recording,
        transcription: transcription,
        calendar: calendarService,
        summaryLimit: summaryLimit
    )

    return CoreFixture(
        core: core,
        store: store,
        fakeRecorder: fakeRecorder,
        fakeEngine: fakeEngine,
        storageRoot: storageRoot,
        permissions: permissions,
        calendarService: calendarService,
        fakeEventStore: fakeEventStore
    )
}
