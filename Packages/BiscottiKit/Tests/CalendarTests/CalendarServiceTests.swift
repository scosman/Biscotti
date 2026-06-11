import Calendar
import DataStore
import Foundation
import MeetingCatalog
import Testing

// MARK: - Fake EventStoreProvider

/// Scripted fake for `EventStoreProviding` that returns pre-configured data.
struct FakeEventStoreProvider: EventStoreProviding {
    var authStatus: CalendarAuthStatus = .authorized
    var accessResult: Bool = true
    var calendarList: [CalendarInfo] = []
    var eventList: [EKEventDTO] = []
    /// Calendar IDs passed to the last `events(in:calendars:)` call.
    var lastCalendarFilter: [String]??
    var eventsCallCount = 0

    /// If set, `refreshEvent` returns this DTO; otherwise nil (event deleted).
    var refreshResult: EKEventDTO?

    /// Mutable state tracked across calls
    private final class State: @unchecked Sendable {
        var eventsCallCount = 0
        var lastCalendarFilter: [String]??
    }

    private let state = State()

    func authorizationStatus() -> CalendarAuthStatus {
        authStatus
    }

    func requestAccess() async throws -> Bool {
        accessResult
    }

    func calendars() -> [CalendarInfo] {
        calendarList
    }

    func events(
        in _: DateInterval,
        calendars: [String]?
    ) -> [EKEventDTO] {
        state.eventsCallCount += 1
        state.lastCalendarFilter = .some(calendars)
        return eventList
    }

    func refreshEvent(
        eventIdentifier _: String,
        occurrenceStart _: Date
    ) -> EKEventDTO? {
        refreshResult
    }

    /// How many times `events(in:calendars:)` was called.
    var callCount: Int {
        state.eventsCallCount
    }

    /// The calendar filter passed in the last call.
    var lastFilter: [String]?? {
        state.lastCalendarFilter
    }
}

// MARK: - Test Helpers

/// Fixed reference instant so tests are deterministic regardless of wall clock.
private let now = Date(timeIntervalSince1970: 1_700_000_000)
private let oneHourAgo = now.addingTimeInterval(-3600)
private let halfHourAgo = now.addingTimeInterval(-1800)
private let twoMinAgo = now.addingTimeInterval(-120)
private let fiveMinFromNow = now.addingTimeInterval(300)
private let thirtyMinFromNow = now.addingTimeInterval(1800)
private let oneHourFromNow = now.addingTimeInterval(3600)
private let twoHoursFromNow = now.addingTimeInterval(7200)

private func makeDTO(
    eventIdentifier: String = "evt-1",
    calendarItemIdentifier: String = "cal-item-1",
    calendarItemExternalIdentifier: String = "ext-1",
    occurrenceDate: Date = now,
    title: String? = "Test Meeting",
    startDate: Date = now,
    endDate: Date = now.addingTimeInterval(3600),
    isAllDay: Bool = false,
    location: String? = nil,
    url: URL? = nil,
    timeZone: String? = "America/New_York",
    notes: String? = nil,
    status: String? = "confirmed",
    availability: String? = "busy",
    calendarIdentifier: String = "cal-A",
    calendarTitle: String = "Work",
    calendarColorHex: String = "#FF0000",
    calendarSourceTitle: String = "iCloud",
    birthdayContactIdentifier: String? = nil,
    attendeeCount: Int = 3,
    attendees: [AttendeeDTO] = [],
    organizer: AttendeeDTO? = nil
) -> EKEventDTO {
    EKEventDTO(
        eventIdentifier: eventIdentifier,
        calendarItemIdentifier: calendarItemIdentifier,
        calendarItemExternalIdentifier: calendarItemExternalIdentifier,
        occurrenceDate: occurrenceDate,
        title: title,
        startDate: startDate,
        endDate: endDate,
        isAllDay: isAllDay,
        location: location,
        url: url,
        timeZone: timeZone,
        notes: notes,
        status: status,
        availability: availability,
        calendarIdentifier: calendarIdentifier,
        calendarTitle: calendarTitle,
        calendarColorHex: calendarColorHex,
        calendarSourceTitle: calendarSourceTitle,
        birthdayContactIdentifier: birthdayContactIdentifier,
        attendeeCount: attendeeCount,
        attendees: attendees,
        organizer: organizer
    )
}

private func makeStore() throws -> DataStore {
    try DataStore(storage: .inMemory)
}

private let window24h = DateInterval(
    start: now,
    end: now.addingTimeInterval(24 * 3600)
)

/// Creates a service, refreshes upcoming, and returns the service.
@MainActor
private func serviceWithEvents(
    _ events: [EKEventDTO],
    store: DataStore? = nil,
    refreshResult: EKEventDTO? = nil,
    window: DateInterval = window24h
) async throws -> CalendarService {
    var provider = FakeEventStoreProvider()
    provider.eventList = events
    provider.refreshResult = refreshResult
    let service = try CalendarService(
        store: store ?? makeStore(),
        catalog: BundledMeetingCatalog(),
        provider: provider
    )
    await service.refreshUpcoming(window: window)
    return service
}

// MARK: - Authorization Tests

@Suite("CalendarService — Authorization")
struct AuthorizationTests {
    @Test("writeOnly maps to denied")
    @MainActor
    func writeOnlyMapsToDenied() throws {
        var provider = FakeEventStoreProvider()
        provider.authStatus = .denied // writeOnly maps to .denied at the provider level
        let service = try CalendarService(
            store: makeStore(),
            catalog: BundledMeetingCatalog(),
            provider: provider
        )
        #expect(service.auth == .denied)
    }

    @Test("restricted maps to restricted")
    @MainActor
    func restrictedMapsToRestricted() throws {
        var provider = FakeEventStoreProvider()
        provider.authStatus = .restricted
        let service = try CalendarService(
            store: makeStore(),
            catalog: BundledMeetingCatalog(),
            provider: provider
        )
        #expect(service.auth == .restricted)
    }

    @Test("requestAccess granted updates auth")
    @MainActor
    func requestAccessGrantedUpdatesAuth() async throws {
        let provider = GrantingProvider()
        let service = try CalendarService(
            store: makeStore(),
            catalog: BundledMeetingCatalog(),
            provider: provider
        )
        #expect(service.auth == .notDetermined)
        let result = await service.requestAccess()
        #expect(result == .authorized)
        #expect(service.auth == .authorized)
    }

    @Test("requestAccess denied updates auth")
    @MainActor
    func requestAccessDeniedUpdatesAuth() async throws {
        let provider = DenyingProvider()
        let service = try CalendarService(
            store: makeStore(),
            catalog: BundledMeetingCatalog(),
            provider: provider
        )
        #expect(service.auth == .notDetermined)
        let result = await service.requestAccess()
        #expect(result == .denied)
        #expect(service.auth == .denied)
    }
}

// MARK: - Stateful providers for auth tests

/// Provider that starts notDetermined and transitions to authorized after requestAccess.
private final class GrantingProvider: EventStoreProviding, @unchecked Sendable {
    private var granted = false

    func authorizationStatus() -> CalendarAuthStatus {
        granted ? .authorized : .notDetermined
    }

    func requestAccess() async throws -> Bool {
        granted = true
        return true
    }

    func calendars() -> [CalendarInfo] {
        []
    }

    func events(in _: DateInterval, calendars _: [String]?) -> [EKEventDTO] {
        []
    }

    func refreshEvent(eventIdentifier _: String, occurrenceStart _: Date) -> EKEventDTO? {
        nil
    }
}

/// Provider that starts notDetermined and transitions to denied after requestAccess.
private final class DenyingProvider: EventStoreProviding, @unchecked Sendable {
    private var denied = false

    func authorizationStatus() -> CalendarAuthStatus {
        denied ? .denied : .notDetermined
    }

    func requestAccess() async throws -> Bool {
        denied = true
        return false
    }

    func calendars() -> [CalendarInfo] {
        []
    }

    func events(in _: DateInterval, calendars _: [String]?) -> [EKEventDTO] {
        []
    }

    func refreshEvent(eventIdentifier _: String, occurrenceStart _: Date) -> EKEventDTO? {
        nil
    }
}

// MARK: - Calendar Enumeration Tests

@Suite("CalendarService — Calendar Enumeration")
struct CalendarEnumerationTests {
    @Test("calendars returns all from provider")
    @MainActor
    func calendarsReturnsAllFromProvider() async throws {
        var provider = FakeEventStoreProvider()
        provider.calendarList = [
            CalendarInfo(id: "cal-1", title: "Work", colorHex: "#FF0000", sourceTitle: "iCloud"),
            CalendarInfo(id: "cal-2", title: "Personal", colorHex: "#00FF00", sourceTitle: "iCloud"),
            CalendarInfo(id: "cal-3", title: "Shared", colorHex: "#0000FF", sourceTitle: "Google")
        ]
        let service = try CalendarService(
            store: makeStore(),
            catalog: BundledMeetingCatalog(),
            provider: provider
        )
        let cals = await service.calendars()
        #expect(cals.count == 3)
        #expect(cals[0].id == "cal-1")
        #expect(cals[0].title == "Work")
        #expect(cals[0].colorHex == "#FF0000")
        #expect(cals[0].sourceTitle == "iCloud")
        #expect(cals[2].sourceTitle == "Google")
    }
}

// MARK: - Enabled Calendar Filtering Tests

@Suite("CalendarService — Enabled Calendar Filtering")
struct EnabledCalendarFilterTests {
    @Test("default all on passes nil to provider")
    @MainActor
    func enabledCalendarFilterDefaultsAllOn() async throws {
        let eventA = makeDTO(eventIdentifier: "e1", calendarIdentifier: "cal-A", calendarTitle: "Work")
        let eventB = makeDTO(eventIdentifier: "e2", calendarIdentifier: "cal-B", calendarTitle: "Personal")
        var provider = FakeEventStoreProvider()
        provider.eventList = [eventA, eventB]

        let service = try CalendarService(
            store: makeStore(),
            catalog: BundledMeetingCatalog(),
            provider: provider
        )
        await service.refreshUpcoming(window: window24h)
        #expect(service.upcoming.count == 2)
        #expect(provider.lastFilter == .some(nil))
    }

    @Test("enabled calendar filter excludes disabled")
    @MainActor
    func enabledCalendarFilterExcludesDisabled() async throws {
        let store = try makeStore()
        try await store.updateSettings { $0.enabledCalendarIDs = ["cal-A"] }

        let eventA = makeDTO(eventIdentifier: "e1", calendarIdentifier: "cal-A", calendarTitle: "Work")
        let eventB = makeDTO(eventIdentifier: "e2", calendarIdentifier: "cal-B", calendarTitle: "Personal")
        var provider = FakeEventStoreProvider()
        provider.eventList = [eventA, eventB]

        let service = CalendarService(
            store: store,
            catalog: BundledMeetingCatalog(),
            provider: provider
        )
        await service.refreshUpcoming(window: window24h)

        if let filter = provider.lastFilter {
            #expect(filter != nil)
            #expect(try #require(filter?.contains("cal-A")))
        }
    }
}

// MARK: - Meeting-Like Filter Tests

@Suite("CalendarService — Meeting-Like Filter")
struct MeetingLikeFilterTests {
    @Test("excludes all-day and solo events")
    @MainActor
    func meetingLikeFilterExcludesAllDayAndSolo() async throws {
        let allDay = makeDTO(eventIdentifier: "e1", isAllDay: true, attendeeCount: 5)
        let soloTimed = makeDTO(eventIdentifier: "e2", isAllDay: false, attendeeCount: 1)
        let multiAttendee = makeDTO(eventIdentifier: "e3", isAllDay: false, attendeeCount: 3)
        let service = try await serviceWithEvents([allDay, soloTimed, multiAttendee])
        #expect(service.upcoming.count == 1)
        #expect(service.upcoming.first?.attendeeCount == 3)
    }

    @Test("includes conference solo event")
    @MainActor
    func meetingLikeFilterIncludesConferenceSolo() async throws {
        let soloWithZoom = try makeDTO(
            eventIdentifier: "e1",
            url: #require(URL(string: "https://us04web.zoom.us/j/12345678")),
            attendeeCount: 1
        )
        let service = try await serviceWithEvents([soloWithZoom])
        #expect(service.upcoming.count == 1)
        #expect(service.upcoming.first?.conferencePlatform == "Zoom")
    }

    @Test("excludes birthday events")
    @MainActor
    func meetingLikeFilterExcludesBirthdayEvents() async throws {
        let birthday = makeDTO(
            eventIdentifier: "e1",
            birthdayContactIdentifier: "contact-123",
            attendeeCount: 3
        )
        let service = try await serviceWithEvents([birthday])
        #expect(service.upcoming.isEmpty)
    }
}

// MARK: - Conference Detection Tests

@Suite("CalendarService — Conference Detection")
struct ConferenceDetectionTests {
    @Test("prefers URL over notes")
    @MainActor
    func conferenceDetectionPrefersURLOverNotes() async throws {
        let event = try makeDTO(
            eventIdentifier: "e1",
            url: #require(URL(string: "https://us04web.zoom.us/j/12345678")),
            notes: "Join at https://meet.google.com/abc-defg-hij",
            attendeeCount: 2
        )
        let service = try await serviceWithEvents([event])
        let found = try #require(service.upcoming.first)
        #expect(found.conferencePlatform == "Zoom")
        #expect(found.conferenceURL?.absoluteString.contains("zoom.us") == true)
    }

    @Test("falls to location")
    @MainActor
    func conferenceDetectionFallsToLocation() async throws {
        let event = makeDTO(
            eventIdentifier: "e1",
            location: "https://teams.microsoft.com/l/meetup-join/abc123",
            notes: "https://meet.google.com/xyz-abcd-efg",
            attendeeCount: 2
        )
        let service = try await serviceWithEvents([event])
        let found = try #require(service.upcoming.first)
        #expect(found.conferencePlatform == "Microsoft Teams")
    }

    @Test("nil when no match")
    @MainActor
    func conferenceDetectionNilWhenNoMatch() async throws {
        let event = makeDTO(
            eventIdentifier: "e1",
            location: "Room 42",
            notes: "Bring your laptop",
            attendeeCount: 3
        )
        let service = try await serviceWithEvents([event])
        let found = try #require(service.upcoming.first)
        #expect(found.conferenceURL == nil)
        #expect(found.conferencePlatform == nil)
    }
}

// MARK: - bestMatch Tests

@Suite("CalendarService — bestMatch")
struct BestMatchTests {
    @Test("picks in-progress conference event")
    @MainActor
    func bestMatchPicksInProgressConferenceEvent() async throws {
        let noConf = makeDTO(
            eventIdentifier: "e1",
            calendarItemIdentifier: "ci-1",
            occurrenceDate: oneHourAgo,
            startDate: oneHourAgo,
            endDate: oneHourFromNow,
            attendeeCount: 3
        )
        let withConf = try makeDTO(
            eventIdentifier: "e2",
            calendarItemIdentifier: "ci-2",
            occurrenceDate: oneHourAgo,
            startDate: oneHourAgo,
            endDate: oneHourFromNow,
            url: #require(URL(string: "https://us04web.zoom.us/j/99999")),
            attendeeCount: 3
        )
        let service = try await serviceWithEvents(
            [noConf, withConf],
            window: DateInterval(start: oneHourAgo, end: twoHoursFromNow)
        )
        let match = service.bestMatch(at: now)
        #expect(match != nil)
        #expect(match?.conferenceURL != nil)
    }

    @Test("picks imminent over none")
    @MainActor
    func bestMatchPicksImminentOverNone() async throws {
        let imminent = makeDTO(
            eventIdentifier: "e1",
            calendarItemIdentifier: "ci-1",
            occurrenceDate: fiveMinFromNow,
            startDate: fiveMinFromNow,
            endDate: oneHourFromNow,
            attendeeCount: 3
        )
        let service = try await serviceWithEvents(
            [imminent],
            window: DateInterval(start: now, end: twoHoursFromNow)
        )
        let match = service.bestMatch(at: now)
        #expect(match != nil)
    }

    @Test("returns nil outside window")
    @MainActor
    func bestMatchReturnsNilOutsideWindow() async throws {
        let tooFar = makeDTO(
            eventIdentifier: "e1",
            calendarItemIdentifier: "ci-1",
            occurrenceDate: thirtyMinFromNow,
            startDate: thirtyMinFromNow,
            endDate: twoHoursFromNow,
            attendeeCount: 3
        )
        let service = try await serviceWithEvents(
            [tooFar],
            window: DateInterval(start: now, end: twoHoursFromNow)
        )
        let match = service.bestMatch(at: now)
        #expect(match == nil)
    }

    @Test("breaks tie by nearest start")
    @MainActor
    func bestMatchBreaksTieByNearestStart() async throws {
        let startedLongAgo = try makeDTO(
            eventIdentifier: "e1",
            calendarItemIdentifier: "ci-1",
            occurrenceDate: halfHourAgo,
            startDate: halfHourAgo,
            endDate: oneHourFromNow,
            url: #require(URL(string: "https://us04web.zoom.us/j/11111")),
            attendeeCount: 3
        )
        let startedRecently = try makeDTO(
            eventIdentifier: "e2",
            calendarItemIdentifier: "ci-2",
            occurrenceDate: twoMinAgo,
            startDate: twoMinAgo,
            endDate: oneHourFromNow,
            url: #require(URL(string: "https://us04web.zoom.us/j/22222")),
            attendeeCount: 3
        )
        let service = try await serviceWithEvents(
            [startedLongAgo, startedRecently],
            window: DateInterval(start: halfHourAgo, end: twoHoursFromNow)
        )
        let match = service.bestMatch(at: now)
        let key2 = CompositeKey.make(
            eventIdentifier: "e2",
            calendarItemIdentifier: "ci-2",
            occurrenceStartDate: twoMinAgo
        )
        #expect(match?.id == key2)
    }
}

// MARK: - Snapshot Core Field Tests

@Suite("CalendarService — Snapshot Core Fields")
struct SnapshotCoreFieldTests {
    @Test("snapshot maps all core fields")
    @MainActor
    func snapshotMapsAllCoreFields() async throws {
        let startDate = now
        let endDate = startDate.addingTimeInterval(3600)
        let dto = try makeDTO(
            eventIdentifier: "evt-snap",
            calendarItemIdentifier: "ci-snap",
            calendarItemExternalIdentifier: "ext-snap",
            occurrenceDate: startDate,
            title: "Standup",
            startDate: startDate,
            endDate: endDate,
            location: "Room A",
            url: #require(URL(string: "https://us04web.zoom.us/j/555")),
            timeZone: "America/New_York",
            notes: "Agenda: review",
            status: "confirmed",
            availability: "busy",
            calendarTitle: "Work",
            calendarColorHex: "#00FF00",
            attendeeCount: 2
        )
        let service = try await serviceWithEvents(
            [dto],
            refreshResult: dto,
            window: DateInterval(
                start: startDate.addingTimeInterval(-60),
                end: endDate.addingTimeInterval(60)
            )
        )
        let key = CompositeKey.make(
            eventIdentifier: "evt-snap",
            calendarItemIdentifier: "ci-snap",
            occurrenceStartDate: startDate
        )
        let snap = try #require(await service.snapshot(forKey: key))
        verifyCoreFields(snap)
    }

    private func verifyCoreFields(_ snap: CalendarSnapshotInput) {
        #expect(snap.eventIdentifier == "evt-snap")
        #expect(snap.calendarItemIdentifier == "ci-snap")
        #expect(snap.calendarItemExternalIdentifier == "ext-snap")
        #expect(snap.title == "Standup")
        #expect(snap.location == "Room A")
        #expect(snap.timeZone == "America/New_York")
        #expect(snap.eventNotes == "Agenda: review")
        #expect(snap.status == "confirmed")
        #expect(snap.availability == "busy")
        #expect(snap.calendarTitle == "Work")
        #expect(snap.calendarColorHex == "#00FF00")
        #expect(snap.conferencePlatform == "Zoom")
        #expect(snap.conferenceURL?.absoluteString.contains("zoom.us") == true)
    }

    @Test("snapshot returns nil for deleted event")
    @MainActor
    func snapshotReturnsNilForDeletedEvent() async throws {
        let startDate = now
        let dto = makeDTO(
            eventIdentifier: "evt-del",
            calendarItemIdentifier: "ci-del",
            occurrenceDate: startDate,
            startDate: startDate,
            endDate: startDate.addingTimeInterval(3600),
            attendeeCount: 2
        )
        // refreshResult = nil means event was deleted
        let service = try await serviceWithEvents(
            [dto],
            refreshResult: nil,
            window: DateInterval(
                start: startDate.addingTimeInterval(-60),
                end: startDate.addingTimeInterval(3660)
            )
        )
        let key = CompositeKey.make(
            eventIdentifier: "evt-del",
            calendarItemIdentifier: "ci-del",
            occurrenceStartDate: startDate
        )
        let snap = await service.snapshot(forKey: key)
        #expect(snap == nil)
    }
}

// MARK: - Snapshot Attendee Tests

@Suite("CalendarService — Snapshot Attendees")
struct SnapshotAttendeeTests {
    private static let sampleAttendees = [
        AttendeeDTO(
            name: "Alice", participantURL: URL(string: "mailto:alice@example.com"),
            isCurrentUser: false, role: "required", status: "accepted", type: "person"
        ),
        AttendeeDTO(
            name: "Bob", participantURL: URL(string: "mailto:bob@example.com"),
            isCurrentUser: true, role: "required", status: "accepted", type: "person"
        ),
        AttendeeDTO(
            name: "Carol", participantURL: URL(string: "mailto:carol@example.com"),
            isCurrentUser: false, role: "optional", status: "tentative", type: "person"
        )
    ]

    private static let sampleOrganizer = AttendeeDTO(
        name: "Alice", participantURL: URL(string: "mailto:alice@example.com"),
        isCurrentUser: false, role: "chair", status: "accepted", type: "person"
    )

    @Test("snapshot maps attendees to AttendeeInputs")
    @MainActor
    func snapshotMapsAttendeesToAttendeeInputs() async throws {
        let snap = try await buildAttendeeSnapshot()
        #expect(snap.attendees.count == 3)

        let alice = try #require(snap.attendees.first { $0.name == "Alice" })
        #expect(alice.email == "alice@example.com")
        #expect(alice.role == "required")
        #expect(alice.status == "accepted")

        let bob = try #require(snap.attendees.first { $0.name == "Bob" })
        #expect(bob.isCurrentUser == true)

        let carol = try #require(snap.attendees.first { $0.name == "Carol" })
        #expect(carol.role == "optional")
        #expect(carol.status == "tentative")

        let org = try #require(snap.organizer)
        #expect(org.name == "Alice")
        #expect(org.email == "alice@example.com")
        #expect(org.role == "chair")
    }

    @MainActor
    private func buildAttendeeSnapshot() async throws -> CalendarSnapshotInput {
        let startDate = now
        let endDate = startDate.addingTimeInterval(3600)
        let dto = makeDTO(
            eventIdentifier: "evt-att",
            calendarItemIdentifier: "ci-att",
            occurrenceDate: startDate,
            startDate: startDate,
            endDate: endDate,
            attendeeCount: 3,
            attendees: Self.sampleAttendees,
            organizer: Self.sampleOrganizer
        )
        let service = try await serviceWithEvents(
            [dto],
            refreshResult: dto,
            window: DateInterval(
                start: startDate.addingTimeInterval(-60),
                end: endDate.addingTimeInterval(60)
            )
        )
        let key = CompositeKey.make(
            eventIdentifier: "evt-att",
            calendarItemIdentifier: "ci-att",
            occurrenceStartDate: startDate
        )
        return try #require(await service.snapshot(forKey: key))
    }

    @Test("snapshot email from mailto parses correctly")
    @MainActor
    func snapshotEmailFromMailtoParsesCorrectly() async throws {
        let startDate = now
        let dto = makeDTO(
            eventIdentifier: "evt-mail",
            calendarItemIdentifier: "ci-mail",
            occurrenceDate: startDate,
            startDate: startDate,
            endDate: startDate.addingTimeInterval(3600),
            attendeeCount: 2,
            attendees: [
                AttendeeDTO(
                    name: "Test",
                    participantURL: URL(string: "mailto:alice@example.com"),
                    isCurrentUser: false, role: "required", status: "accepted", type: "person"
                )
            ]
        )
        let service = try await serviceWithEvents(
            [dto],
            refreshResult: dto,
            window: DateInterval(
                start: startDate.addingTimeInterval(-60),
                end: startDate.addingTimeInterval(3660)
            )
        )
        let key = CompositeKey.make(
            eventIdentifier: "evt-mail",
            calendarItemIdentifier: "ci-mail",
            occurrenceStartDate: startDate
        )
        let snap = await service.snapshot(forKey: key)
        let attendee = try #require(snap?.attendees.first)
        #expect(attendee.email == "alice@example.com")
    }

    @Test("snapshot email nil for non-mailto URL")
    @MainActor
    func snapshotEmailNilForNonMailtoURL() async throws {
        let startDate = now
        let dto = makeDTO(
            eventIdentifier: "evt-x500",
            calendarItemIdentifier: "ci-x500",
            occurrenceDate: startDate,
            startDate: startDate,
            endDate: startDate.addingTimeInterval(3600),
            attendeeCount: 2,
            attendees: [
                AttendeeDTO(
                    name: "Exchange User",
                    participantURL: URL(string: "x500:/o=org/cn=user"),
                    isCurrentUser: false, role: "required", status: "accepted", type: "person"
                )
            ]
        )
        let service = try await serviceWithEvents(
            [dto],
            refreshResult: dto,
            window: DateInterval(
                start: startDate.addingTimeInterval(-60),
                end: startDate.addingTimeInterval(3660)
            )
        )
        let key = CompositeKey.make(
            eventIdentifier: "evt-x500",
            calendarItemIdentifier: "ci-x500",
            occurrenceStartDate: startDate
        )
        let snap = await service.snapshot(forKey: key)
        let attendee = try #require(snap?.attendees.first)
        #expect(attendee.email == nil)
    }
}

// MARK: - Composite Key Tests

@Suite("CalendarService — Composite Key")
struct CompositeKeyTests {
    @Test("composite key includes all components")
    func compositeKeyIncludesAllComponents() {
        let date = Date(timeIntervalSince1970: 1_700_000_000)
        let key = CompositeKey.make(
            eventIdentifier: "abc",
            calendarItemIdentifier: "def",
            occurrenceStartDate: date
        )
        let timestamp = Int64(date.timeIntervalSince1970)
        #expect(key == "abc|def|\(timestamp)")
        #expect(key.contains("abc"))
        #expect(key.contains("def"))
        #expect(key.contains("|"))
    }
}

// MARK: - event(forKey:) Tests

@Suite("CalendarService — event(forKey:)")
struct EventForKeyTests {
    @Test("returns match from upcoming")
    @MainActor
    func eventForKeyReturnsMatchFromUpcoming() async throws {
        let startDate = now
        let dto1 = makeDTO(
            eventIdentifier: "e1",
            calendarItemIdentifier: "ci-1",
            occurrenceDate: startDate,
            title: "First",
            startDate: startDate,
            endDate: startDate.addingTimeInterval(3600),
            attendeeCount: 3
        )
        let dto2 = makeDTO(
            eventIdentifier: "e2",
            calendarItemIdentifier: "ci-2",
            occurrenceDate: startDate,
            title: "Second",
            startDate: startDate,
            endDate: startDate.addingTimeInterval(3600),
            attendeeCount: 3
        )
        let service = try await serviceWithEvents(
            [dto1, dto2],
            window: DateInterval(
                start: startDate.addingTimeInterval(-60),
                end: startDate.addingTimeInterval(3660)
            )
        )
        let key = CompositeKey.make(
            eventIdentifier: "e1",
            calendarItemIdentifier: "ci-1",
            occurrenceStartDate: startDate
        )
        let found = service.event(forKey: key)
        #expect(found?.title == "First")
    }

    @Test("returns nil for unknown key")
    @MainActor
    func eventForKeyReturnsNilForUnknownKey() async throws {
        let service = try await serviceWithEvents([])
        let found = service.event(forKey: "nonexistent")
        #expect(found == nil)
    }
}

// MARK: - Staleness / Observation Tests

@Suite("CalendarService — Staleness & Observation")
struct StalenessTests {
    @Test("stale marked when event deleted")
    @MainActor
    func staleMarkedWhenEventDeleted() async throws {
        let store = try makeStore()
        let startDate = Date()

        let meetingID = try await store.createMeeting(title: "Linked Meeting", start: startDate)
        let snapshot = CalendarSnapshot(
            eventIdentifier: "evt-stale",
            calendarItemIdentifier: "ci-stale",
            occurrenceStartDate: startDate,
            compositeKey: "evt-stale|ci-stale|\(Int64(startDate.timeIntervalSince1970))",
            title: "Linked Meeting",
            startDate: startDate,
            endDate: startDate.addingTimeInterval(3600)
        )
        try await store.setSnapshot(snapshot, for: meetingID)

        var provider = FakeEventStoreProvider()
        provider.eventList = []
        provider.refreshResult = nil

        let service = CalendarService(
            store: store,
            catalog: BundledMeetingCatalog(),
            provider: provider
        )
        service.startObserving()
        NotificationCenter.default.post(name: .EKEventStoreChanged, object: nil)

        // Poll until the notification handler's Task marks the snapshot stale.
        var isStale = false
        let deadline = ContinuousClock.now.advanced(by: .seconds(2))
        while !isStale, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
            let context = try await store.calendarContext(meetingID: meetingID)
            isStale = context?.isStale == true
        }

        #expect(isStale == true)
    }

    @Test("refresh upcoming called on store changed")
    @MainActor
    func refreshUpcomingCalledOnStoreChanged() async throws {
        let startDate = Date()
        let dto = makeDTO(
            eventIdentifier: "e1",
            calendarItemIdentifier: "ci-1",
            occurrenceDate: startDate,
            startDate: startDate,
            endDate: startDate.addingTimeInterval(3600),
            attendeeCount: 3
        )
        let provider = CallCountProvider(events: [dto])

        let service = try CalendarService(
            store: makeStore(),
            catalog: BundledMeetingCatalog(),
            provider: provider
        )
        service.startObserving()
        let countBefore = provider.eventsCallCount

        NotificationCenter.default.post(name: .EKEventStoreChanged, object: nil)

        // Poll until the notification handler's Task runs, rather than
        // relying on a fixed sleep (the handler enqueues a MainActor Task
        // that needs cooperative scheduling to execute).
        let deadline = ContinuousClock.now.advanced(by: .seconds(2))
        while provider.eventsCallCount <= countBefore,
              ContinuousClock.now < deadline
        {
            try await Task.sleep(for: .milliseconds(10))
        }

        #expect(provider.eventsCallCount > countBefore)
    }
}

/// Provider that tracks call counts for observation tests.
private final class CallCountProvider: EventStoreProviding, @unchecked Sendable {
    private let _events: [EKEventDTO]
    private var _eventsCallCount = 0

    var eventsCallCount: Int {
        _eventsCallCount
    }

    init(events: [EKEventDTO]) {
        _events = events
    }

    func authorizationStatus() -> CalendarAuthStatus {
        .authorized
    }

    func requestAccess() async throws -> Bool {
        true
    }

    func calendars() -> [CalendarInfo] {
        []
    }

    func events(in _: DateInterval, calendars _: [String]?) -> [EKEventDTO] {
        _eventsCallCount += 1
        return _events
    }

    func refreshEvent(eventIdentifier _: String, occurrenceStart _: Date) -> EKEventDTO? {
        nil
    }
}
