import BiscottiTestSupport
import Calendar
import DataStore
import Foundation
import Testing
import Transcription
@testable import AppCore
@testable import MeetingDetailUI
@testable import Recording

// MARK: - Editable title tests

@Suite("MeetingDetailViewModel -- editable title")
struct MeetingDetailEditableTitleTests {
    @Test("editableTitle loaded from store on load")
    @MainActor
    func editableTitleLoadedFromStore() async throws {
        let fix = try makeCoreFixture(testName: "G3aTitle")
        defer { fix.cleanup() }

        let meetingID = try await fix.store.createMeeting(
            title: "My Important Meeting"
        )

        let viewModel = MeetingDetailViewModel(
            core: fix.core,
            meetingID: meetingID,
            makePlayer: { G3aFakePlayer() }
        )
        await viewModel.load()

        #expect(viewModel.editableTitle == "My Important Meeting")
    }

    @Test("saveTitle persists to DataStore")
    @MainActor
    func saveTitlePersistsToStore() async throws {
        let fix = try makeCoreFixture(testName: "G3aTitle")
        defer { fix.cleanup() }

        let meetingID = try await fix.store.createMeeting(
            title: "Original Title"
        )

        let viewModel = MeetingDetailViewModel(
            core: fix.core,
            meetingID: meetingID,
            makePlayer: { G3aFakePlayer() }
        )
        await viewModel.load()

        viewModel.editableTitle = "Updated Title"
        await viewModel.saveTitle()

        // Verify persisted
        let detail = try await fix.store.meetingDetail(id: meetingID)
        #expect(detail?.title == "Updated Title")

        // VM reflects the saved title
        #expect(viewModel.editableTitle == "Updated Title")
    }

    @Test("saveTitle trims whitespace")
    @MainActor
    func saveTitleTrimsWhitespace() async throws {
        let fix = try makeCoreFixture(testName: "G3aTitle")
        defer { fix.cleanup() }

        let meetingID = try await fix.store.createMeeting(
            title: "Original"
        )

        let viewModel = MeetingDetailViewModel(
            core: fix.core,
            meetingID: meetingID,
            makePlayer: { G3aFakePlayer() }
        )
        await viewModel.load()

        viewModel.editableTitle = "  Padded Title  "
        await viewModel.saveTitle()

        let detail = try await fix.store.meetingDetail(id: meetingID)
        #expect(detail?.title == "Padded Title")
        #expect(viewModel.editableTitle == "Padded Title")
    }

    @Test("saveTitle reverts blank title to stored value")
    @MainActor
    func saveTitleRevertsBlank() async throws {
        let fix = try makeCoreFixture(testName: "G3aTitle")
        defer { fix.cleanup() }

        let meetingID = try await fix.store.createMeeting(
            title: "Original Title"
        )

        let viewModel = MeetingDetailViewModel(
            core: fix.core,
            meetingID: meetingID,
            makePlayer: { G3aFakePlayer() }
        )
        await viewModel.load()

        viewModel.editableTitle = "   "
        await viewModel.saveTitle()

        // Should revert to the stored title
        #expect(viewModel.editableTitle == "Original Title")
        let detail = try await fix.store.meetingDetail(id: meetingID)
        #expect(detail?.title == "Original Title")
    }

    @Test("saveTitle updates sidebar summaries")
    @MainActor
    func saveTitleUpdatesSidebar() async throws {
        let fix = try makeCoreFixture(testName: "G3aTitle")
        defer { fix.cleanup() }

        let meetingID = try await fix.store.createMeeting(
            title: "Old Title"
        )
        await fix.core.reloadSummaries()
        #expect(
            fix.core.summaries.first(where: { $0.id == meetingID })?
                .title == "Old Title"
        )

        let viewModel = MeetingDetailViewModel(
            core: fix.core,
            meetingID: meetingID,
            makePlayer: { G3aFakePlayer() }
        )
        await viewModel.load()

        viewModel.editableTitle = "New Title"
        await viewModel.saveTitle()

        #expect(
            fix.core.summaries.first(where: { $0.id == meetingID })?
                .title == "New Title"
        )
    }

    @Test("flushPendingEdits also saves pending title")
    @MainActor
    func flushPendingEditsSavesPendingTitle() async throws {
        let fix = try makeCoreFixture(testName: "G3aTitle")
        defer { fix.cleanup() }

        let meetingID = try await fix.store.createMeeting(
            title: "Original"
        )

        let viewModel = MeetingDetailViewModel(
            core: fix.core,
            meetingID: meetingID,
            makePlayer: { G3aFakePlayer() }
        )
        await viewModel.load()

        viewModel.editableTitle = "Edited via flush"
        await viewModel.flushPendingEdits()

        let detail = try await fix.store.meetingDetail(id: meetingID)
        #expect(detail?.title == "Edited via flush")
    }
}

// MARK: - Auto-title (no date) tests

@Suite("RecordingController -- auto-title has no date")
struct AutoTitleNoDateTests {
    @Test("autoTitle returns a static string with no date components")
    @MainActor
    func autoTitleHasNoDate() {
        let title = RecordingController.autoTitle()
        #expect(title == "Untitled Meeting")
        // Verify no date-like content
        #expect(!title.contains("/"))
        #expect(!title.contains(","))
        #expect(!title.contains("\u{2014}")) // em dash
    }
}

// MARK: - Test helpers

/// Adds an organizer + attendee to a meeting for context tests.
private func setUpParticipants(
    fix: CoreFixture, meetingID: UUID
) async throws {
    let orgID = try await fix.store.findOrCreatePerson(
        name: "Alice", email: "alice@example.com"
    )
    let attID = try await fix.store.findOrCreatePerson(
        name: "Bob", email: "bob@example.com"
    )
    try await fix.store.setParticipants(
        [attID], organizer: orgID, for: meetingID
    )
}

// MARK: - DTO helper

/// Creates an `EKEventDTO` with sensible defaults for association tests.
private func makeEventDTO(
    suffix: String,
    title: String = "Test Event",
    startDate: Date = Date(),
    endDate: Date? = nil,
    location: String? = nil,
    attendeeCount: Int = 2,
    calendarTitle: String = "Work",
    calendarColorHex: String = "#0066CC"
) -> EKEventDTO {
    EKEventDTO(
        eventIdentifier: "ev-\(suffix)",
        calendarItemIdentifier: "ci-\(suffix)",
        calendarItemExternalIdentifier: "ext-\(suffix)",
        occurrenceDate: startDate,
        title: title,
        startDate: startDate,
        endDate: endDate ?? startDate.addingTimeInterval(3600),
        isAllDay: false,
        location: location,
        url: nil,
        timeZone: nil,
        notes: nil,
        status: nil,
        availability: nil,
        calendarIdentifier: "cal-1",
        calendarTitle: calendarTitle,
        calendarColorHex: calendarColorHex,
        calendarSourceTitle: "iCloud",
        birthdayContactIdentifier: nil,
        attendeeCount: attendeeCount,
        attendees: [],
        organizer: nil
    )
}

// MARK: - Snapshot helper

/// Creates a `CalendarSnapshot` with sensible defaults for tests.
private func makeSnapshot(
    suffix: String,
    startDate: Date = Date(),
    endDate: Date? = nil,
    conferenceURL: URL? = nil,
    conferencePlatform: String? = nil,
    calendarTitle: String = "Work",
    calendarColorHex: String = "#0066CC",
    location: String? = nil,
    title: String = "Test Event"
) -> CalendarSnapshot {
    CalendarSnapshot(
        eventIdentifier: "ev-\(suffix)",
        calendarItemIdentifier: "ci-\(suffix)",
        calendarItemExternalIdentifier: "ext-\(suffix)",
        occurrenceStartDate: startDate,
        compositeKey: "key-\(suffix)",
        title: title,
        startDate: startDate,
        endDate: endDate ?? startDate.addingTimeInterval(3600),
        isAllDay: false,
        location: location,
        url: nil,
        timeZone: nil,
        eventNotes: "",
        status: nil,
        availability: nil,
        calendarTitle: calendarTitle,
        calendarColorHex: calendarColorHex,
        conferenceURL: conferenceURL,
        conferencePlatform: conferencePlatform
    )
}

// MARK: - Calendar context visual tests (item 3)

@Suite("MeetingDetailViewModel -- calendar context display")
struct MeetingDetailCalendarContextDisplayTests {
    @Test(
        "calendar context is loaded and displayed when snapshot exists"
    )
    @MainActor
    func calendarContextShowsWhenAssociated() async throws {
        let fix = try makeCoreFixture(testName: "G3aCalCtx")
        defer { fix.cleanup() }

        let now = Date()
        let meetingID = try await fix.store.createMeeting(
            title: "Cal Display"
        )
        try await fix.store.setSnapshot(
            makeSnapshot(
                suffix: "display", startDate: now,
                conferenceURL: URL(string: "https://zoom.us/j/999"),
                conferencePlatform: "Zoom", location: "Room 42",
                title: "Design Review"
            ),
            for: meetingID
        )
        try await setUpParticipants(fix: fix, meetingID: meetingID)

        let viewModel = MeetingDetailViewModel(
            core: fix.core,
            meetingID: meetingID,
            makePlayer: { G3aFakePlayer() }
        )
        await viewModel.load()

        #expect(viewModel.hasCalendarContext == true)
        let ctx = viewModel.calendarContext
        #expect(ctx?.title == "Design Review")
        #expect(ctx?.conferencePlatform == "Zoom")
        #expect(ctx?.calendarTitle == "Work")
        #expect(ctx?.location == "Room 42")
        #expect(ctx?.organizer?.name == "Alice")
        #expect(ctx?.attendees.first?.name == "Bob")
        #expect(ctx?.conferenceURL?.absoluteString == "https://zoom.us/j/999")
        #expect(ctx?.startDate == now)
        #expect(ctx?.endDate == now.addingTimeInterval(3600))
    }

    @Test(
        "single VM: load nearby events, associate, context appears"
    )
    @MainActor
    func singleVMAssociateThenVerify() async throws {
        let dto = makeEventDTO(
            suffix: "single",
            title: "Design Sync",
            location: "https://zoom.us/j/single",
            calendarTitle: "Team",
            calendarColorHex: "#33CC33"
        )

        let fix = try makeCoreFixture(
            calendarEventDTOs: [dto],
            calendarRefreshResult: dto,
            testName: "G3aCalCtx"
        )
        defer { fix.cleanup() }

        let meetingID = try await fix.store.createMeeting(
            title: "Link Test"
        )

        let viewModel = MeetingDetailViewModel(
            core: fix.core,
            meetingID: meetingID,
            makePlayer: { G3aFakePlayer() }
        )
        await viewModel.load()
        #expect(viewModel.hasCalendarContext == false)

        // Load nearby events (uses eventsNear the meeting's date)
        await viewModel.loadNearbyEvents()
        guard let eventKey = viewModel.availableEvents.first?.id else {
            Issue.record("Expected at least one nearby event")
            return
        }
        await viewModel.correctAssociation(eventKey: eventKey)

        #expect(viewModel.hasCalendarContext == true)
        #expect(viewModel.calendarContext?.calendarTitle == "Team")
        #expect(viewModel.calendarContext?.title == "Design Sync")
    }
}

// MARK: - Re-transcribe prompt hidden (item 4)

@Suite("MeetingDetailViewModel -- re-transcribe prompt hidden")
struct MeetingDetailReTranscribeHiddenTests {
    @Test("re-transcribe prompt stays hidden after association correction")
    @MainActor
    func reTranscribePromptHiddenAfterCorrection() async throws {
        let dto = makeEventDTO(
            suffix: "noprompt",
            title: "No Prompt Event",
            location: "https://zoom.us/j/noprompt",
            attendeeCount: 3
        )

        let fix = try makeCoreFixture(
            calendarEventDTOs: [dto],
            calendarRefreshResult: dto,
            testName: "G3aNoPrompt"
        )
        defer { fix.cleanup() }

        let meetingID = try await fix.store.createMeeting(
            title: "No Prompt Test"
        )

        let viewModel = MeetingDetailViewModel(
            core: fix.core,
            meetingID: meetingID,
            makePlayer: { G3aFakePlayer() }
        )
        await viewModel.load()

        await viewModel.loadNearbyEvents()
        guard let eventKey = viewModel.availableEvents.first?.id
        else {
            Issue.record("Expected at least one nearby event")
            return
        }

        // Associate -- prompt must NOT appear
        await viewModel.correctAssociation(eventKey: eventKey)
        #expect(viewModel.showReTranscribeAfterCorrection == false)
    }

    @Test("showReTranscribeAfterCorrection is always false")
    @MainActor
    func flagAlwaysFalse() async throws {
        let fix = try makeCoreFixture(testName: "G3aNoPrompt")
        defer { fix.cleanup() }

        let meetingID = try await fix.store.createMeeting(
            title: "Flag Test"
        )

        let viewModel = MeetingDetailViewModel(
            core: fix.core,
            meetingID: meetingID,
            makePlayer: { G3aFakePlayer() }
        )
        await viewModel.load()

        // Should never be true
        #expect(viewModel.showReTranscribeAfterCorrection == false)
        viewModel.dismissReTranscribePrompt()
        #expect(viewModel.showReTranscribeAfterCorrection == false)
    }
}

// MARK: - Open in Calendar (replaced Join button)

@Suite("MeetingDetailViewModel -- Open in Calendar")
struct MeetingDetailOpenInCalendarTests {
    @Test("openInCalendar uses eventIdentifier URL when available")
    @MainActor
    func openInCalUsesEventIdentifier() async throws {
        let fix = try makeCoreFixture(testName: "G3aOpenCal")
        defer { fix.cleanup() }

        let meetingID = try await fix.store.createMeeting(
            title: "ID Test"
        )
        try await fix.store.setSnapshot(
            makeSnapshot(suffix: "idtest", title: "Design Review"),
            for: meetingID
        )

        var openedURL: URL?
        let viewModel = MeetingDetailViewModel(
            core: fix.core,
            meetingID: meetingID,
            makePlayer: { G3aFakePlayer() },
            urlOpener: { openedURL = $0 }
        )
        await viewModel.load()

        viewModel.openInCalendar()

        #expect(openedURL != nil)
        let urlString = try #require(openedURL?.absoluteString)
        #expect(urlString.contains("ical://ekevent/ev-idtest"))
        #expect(urlString.contains("method=show"))
    }

    @Test("openInCalendar falls back when eventIdentifier is nil")
    @MainActor
    func openInCalFallsBackWithoutIdentifier() async throws {
        let fix = try makeCoreFixture(testName: "G3aOpenCal")
        defer { fix.cleanup() }

        let meetingID = try await fix.store.createMeeting(
            title: "No EID"
        )
        // Snapshot with no eventIdentifier
        let snapshot = CalendarSnapshot(
            eventIdentifier: nil,
            compositeKey: "key-noeid",
            title: "Fallback Event",
            startDate: Date()
        )
        try await fix.store.setSnapshot(snapshot, for: meetingID)

        var openedURL: URL?
        let viewModel = MeetingDetailViewModel(
            core: fix.core,
            meetingID: meetingID,
            makePlayer: { G3aFakePlayer() },
            urlOpener: { openedURL = $0 }
        )
        await viewModel.load()

        viewModel.openInCalendar()

        #expect(openedURL != nil)
        let urlString = try #require(openedURL?.absoluteString)
        #expect(urlString.hasPrefix("ical://"))
    }
}

// MARK: - Association refresh (Item 1)

@Suite("MeetingDetailViewModel -- association refresh")
struct MeetingDetailAssociationRefreshTests {
    @Test(
        "past meeting: eventsNear surfaces event that forward-only upcoming misses"
    )
    @MainActor
    func pastMeetingFindsEventViaNearby() async throws {
        // The event occurred at the same time as the meeting but is
        // NOT in the forward 24h window (upcoming is empty).
        let pastDate = Date()
        let dto = makeEventDTO(
            suffix: "past",
            title: "Past Standup",
            startDate: pastDate,
            location: "https://zoom.us/j/past",
            calendarTitle: "Team",
            calendarColorHex: "#33CC33"
        )

        let fix = try makeCoreFixture(
            calendarEventDTOs: [dto],
            calendarRefreshResult: dto,
            testName: "B2Past"
        )
        defer { fix.cleanup() }

        // Do NOT call onLaunch -- upcoming stays empty, simulating
        // a past recording where the forward window has no events.
        let meetingID = try await fix.store.createMeeting(
            title: "Past Recording"
        )

        let viewModel = MeetingDetailViewModel(
            core: fix.core,
            meetingID: meetingID,
            makePlayer: { G3aFakePlayer() }
        )
        await viewModel.load()

        // upcoming is empty -- old code would show no events
        #expect(fix.core.upcoming.isEmpty)
        #expect(viewModel.availableEvents.isEmpty)

        // loadNearbyEvents fetches events near the meeting's date
        await viewModel.loadNearbyEvents()

        #expect(viewModel.availableEvents.count == 1)
        #expect(
            viewModel.availableEvents.first?.title == "Past Standup"
        )

        // Associate using the nearby event key
        guard let eventKey = viewModel.availableEvents.first?.id else {
            Issue.record("Expected nearby event")
            return
        }
        await viewModel.correctAssociation(eventKey: eventKey)

        // Context appears with real fields, visible without relaunch
        #expect(viewModel.calendarContext != nil)
        #expect(viewModel.hasCalendarContext == true)
        #expect(viewModel.calendarContext?.calendarTitle == "Team")
        #expect(viewModel.calendarContext?.title == "Past Standup")
        #expect(viewModel.editableTitle == "Past Standup")
    }

    @Test(
        "failed snapshot lookup does NOT wipe existing association"
    )
    @MainActor
    func failedLookupPreservesExisting() async throws {
        // Set up a meeting with an existing calendar association
        let fix = try makeCoreFixture(testName: "B2NonDestructive")
        defer { fix.cleanup() }

        let meetingID = try await fix.store.createMeeting(
            title: "Linked Meeting"
        )
        try await fix.store.setSnapshot(
            makeSnapshot(
                suffix: "existing",
                calendarTitle: "Work",
                title: "Existing Event"
            ),
            for: meetingID
        )

        let viewModel = MeetingDetailViewModel(
            core: fix.core,
            meetingID: meetingID,
            makePlayer: { G3aFakePlayer() }
        )
        await viewModel.load()

        // Confirm existing association is present
        #expect(viewModel.hasCalendarContext == true)
        #expect(viewModel.calendarContext?.title == "Existing Event")
        #expect(viewModel.calendarContext?.calendarTitle == "Work")

        // Attempt to associate with a bogus key that cannot be resolved
        // (FakeEventStore has no DTOs cached, so snapshot(forKey:) fails)
        await viewModel.correctAssociation(eventKey: "bogus-key-999")

        // Existing association must be PRESERVED (non-destructive)
        #expect(viewModel.hasCalendarContext == true)
        #expect(viewModel.calendarContext?.title == "Existing Event")
        #expect(viewModel.calendarContext?.calendarTitle == "Work")
    }

    @Test(
        "explicit unlink (nil eventKey) still clears association"
    )
    @MainActor
    func explicitUnlinkClearsContext() async throws {
        let fix = try makeCoreFixture(testName: "B2Unlink")
        defer { fix.cleanup() }

        let meetingID = try await fix.store.createMeeting(
            title: "Clear Test"
        )
        try await fix.store.setSnapshot(
            makeSnapshot(suffix: "clear", title: "Old Event"),
            for: meetingID
        )

        let viewModel = MeetingDetailViewModel(
            core: fix.core,
            meetingID: meetingID,
            makePlayer: { G3aFakePlayer() }
        )
        await viewModel.load()

        #expect(viewModel.hasCalendarContext == true)

        await viewModel.removeAssociation()

        #expect(viewModel.hasCalendarContext == false)
        #expect(viewModel.calendarContext == nil)
    }
}

// MARK: - Cache-eviction race guard (Item 1 follow-up)

@Suite("CalendarService -- candidate cache survives refreshUpcoming")
struct CalendarCandidateCacheRaceTests {
    @Test(
        "refreshUpcoming after eventsNear does not evict candidate; association still resolves"
    )
    @MainActor
    func raceRefreshDoesNotEvictCandidate() async throws {
        let pastDate = Date()
        let dto = makeEventDTO(
            suffix: "race",
            title: "Past Standup",
            startDate: pastDate,
            location: "https://zoom.us/j/race",
            calendarTitle: "Team",
            calendarColorHex: "#33CC33"
        )

        let fix = try makeCoreFixture(
            calendarEventDTOs: [dto],
            calendarRefreshResult: dto,
            testName: "B2Race"
        )
        defer { fix.cleanup() }

        let meetingID = try await fix.store.createMeeting(
            title: "Race Test"
        )

        let viewModel = MeetingDetailViewModel(
            core: fix.core,
            meetingID: meetingID,
            makePlayer: { G3aFakePlayer() }
        )
        await viewModel.load()

        // 1) Load nearby events -- populates candidateDTOs
        await viewModel.loadNearbyEvents()
        #expect(viewModel.availableEvents.count == 1)
        let eventKey = try #require(
            viewModel.availableEvents.first?.id
        )

        // 2) Simulate EKEventStoreChanged: remove the past event from
        //    the fake store's DTOs (it's outside the forward window) and
        //    trigger refreshUpcoming. This replaces cachedDTOs entirely.
        fix.fakeEventStore.eventDTOs = []
        let now = Date()
        await fix.calendarService.refreshUpcoming(
            window: DateInterval(
                start: now,
                end: now.addingTimeInterval(24 * 60 * 60)
            )
        )

        // upcoming is now empty -- cachedDTOs wiped
        #expect(fix.core.upcoming.isEmpty)

        // 3) Associate using the previously-fetched event key.
        //    Before the fix, snapshot(forKey:) would return nil because
        //    cachedDTOs was replaced. With candidateDTOs, it survives.
        await viewModel.correctAssociation(eventKey: eventKey)

        // Context must be present with real fields
        #expect(viewModel.hasCalendarContext == true)
        #expect(viewModel.calendarContext?.title == "Past Standup")
        #expect(viewModel.calendarContext?.calendarTitle == "Team")
    }
}

// MARK: - hasCalendarAccess for picker (Item 4)

@Suite("MeetingDetailViewModel -- calendar access for picker")
struct MeetingDetailCalendarAccessTests {
    @Test("hasCalendarAccess true when authorized")
    @MainActor
    func accessTrueWhenAuthorized() async throws {
        let fix = try makeCoreFixture(
            calendarAuthStatus: .authorized,
            testName: "B2Access"
        )
        defer { fix.cleanup() }

        let meetingID = try await fix.store.createMeeting(
            title: "Access Test"
        )
        let viewModel = MeetingDetailViewModel(
            core: fix.core,
            meetingID: meetingID,
            makePlayer: { G3aFakePlayer() }
        )

        #expect(viewModel.hasCalendarAccess == true)
    }

    @Test("hasCalendarAccess false when denied")
    @MainActor
    func accessFalseWhenDenied() async throws {
        let fix = try makeCoreFixture(
            calendarAuthStatus: .denied,
            testName: "B2Access"
        )
        defer { fix.cleanup() }

        let meetingID = try await fix.store.createMeeting(
            title: "Denied Test"
        )
        let viewModel = MeetingDetailViewModel(
            core: fix.core,
            meetingID: meetingID,
            makePlayer: { G3aFakePlayer() }
        )

        #expect(viewModel.hasCalendarAccess == false)
    }

    @Test("hasCalendarAccess false when notDetermined")
    @MainActor
    func accessFalseWhenNotDetermined() async throws {
        let fix = try makeCoreFixture(
            calendarAuthStatus: .notDetermined,
            testName: "B2Access"
        )
        defer { fix.cleanup() }

        let meetingID = try await fix.store.createMeeting(
            title: "Not Determined Test"
        )
        let viewModel = MeetingDetailViewModel(
            core: fix.core,
            meetingID: meetingID,
            makePlayer: { G3aFakePlayer() }
        )

        #expect(viewModel.hasCalendarAccess == false)
    }
}

// MARK: - N3 regression: saveTitle must not spuriously set editedTitle

@Suite("MeetingDetailViewModel -- saveTitle editedTitle guard (N3)")
struct MeetingDetailSaveTitleGuardTests {
    @Test(
        "saveTitle with unchanged title does not set editedTitle -- auto-title still works"
    )
    @MainActor
    func saveTitleUnchangedDoesNotFlagEdited() async throws {
        let dto = makeEventDTO(
            suffix: "n3-guard",
            title: "Standup",
            location: "https://zoom.us/j/n3",
            calendarTitle: "Team"
        )

        let fix = try makeCoreFixture(
            calendarEventDTOs: [dto],
            calendarRefreshResult: dto,
            testName: "N3Guard"
        )
        defer { fix.cleanup() }

        let meetingID = try await fix.store.createMeeting(
            title: "Untitled Meeting"
        )

        let viewModel = MeetingDetailViewModel(
            core: fix.core,
            meetingID: meetingID,
            makePlayer: { G3aFakePlayer() }
        )
        await viewModel.load()

        // Associate a calendar event -- applies event title via
        // applyEventTitle (editedTitle stays false).
        await viewModel.loadNearbyEvents()
        guard let eventKey = viewModel.availableEvents.first?.id else {
            Issue.record("Expected at least one nearby event")
            return
        }
        await viewModel.correctAssociation(eventKey: eventKey)

        #expect(viewModel.detail?.title == "Standup")
        #expect(viewModel.editableTitle == "Standup")

        // editedTitle must still be false after association
        try await fix.store.read { store in
            let meetingBefore = try store.meeting(id: meetingID)
            #expect(meetingBefore?.editedTitle == false)
        }

        // Simulate onDisappear: flushPendingEdits calls saveTitle. The title
        // hasn't changed, so editedTitle must NOT flip to true.
        await viewModel.flushPendingEdits()

        try await fix.store.read { store in
            let meetingAfter = try store.meeting(id: meetingID)
            #expect(meetingAfter?.editedTitle == false)
        }

        // Because editedTitle is still false, a subsequent association
        // must still be able to update the title via applyEventTitle.
        try await fix.store.applyEventTitle(
            "New Event Name", for: meetingID
        )
        try await fix.store.read { store in
            let meetingFinal = try store.meeting(id: meetingID)
            #expect(meetingFinal?.title == "New Event Name")
        }
    }

    @Test(
        "saveTitle with unchanged title via direct call also skips write"
    )
    @MainActor
    func saveTitleDirectCallSkipsUnchanged() async throws {
        let fix = try makeCoreFixture(testName: "N3Direct")
        defer { fix.cleanup() }

        let meetingID = try await fix.store.createMeeting(
            title: "Original"
        )

        let viewModel = MeetingDetailViewModel(
            core: fix.core,
            meetingID: meetingID,
            makePlayer: { G3aFakePlayer() }
        )
        await viewModel.load()

        // editableTitle == "Original", detail.title == "Original"
        #expect(viewModel.editableTitle == "Original")

        await viewModel.saveTitle()

        // editedTitle must NOT be set
        try await fix.store.read { store in
            let meeting = try store.meeting(id: meetingID)
            #expect(meeting?.editedTitle == false)
        }
    }

    @Test(
        "saveTitle with genuinely changed title persists and sets editedTitle"
    )
    @MainActor
    func saveTitleChangedSetsFlagAndPersists() async throws {
        let fix = try makeCoreFixture(testName: "N3Changed")
        defer { fix.cleanup() }

        let meetingID = try await fix.store.createMeeting(
            title: "Original"
        )

        let viewModel = MeetingDetailViewModel(
            core: fix.core,
            meetingID: meetingID,
            makePlayer: { G3aFakePlayer() }
        )
        await viewModel.load()

        viewModel.editableTitle = "User Renamed"
        await viewModel.saveTitle()

        // Title persisted
        let detail = try await fix.store.meetingDetail(id: meetingID)
        #expect(detail?.title == "User Renamed")
        #expect(viewModel.editableTitle == "User Renamed")

        // editedTitle IS set for genuine edits
        try await fix.store.read { store in
            let meeting = try store.meeting(id: meetingID)
            #expect(meeting?.editedTitle == true)
        }

        // applyEventTitle no longer overwrites (user edit wins)
        try await fix.store.applyEventTitle(
            "Calendar Title", for: meetingID
        )
        try await fix.store.read { store in
            let meetingAfter = try store.meeting(id: meetingID)
            #expect(meetingAfter?.title == "User Renamed")
        }
    }
}

// MARK: - N2 regression: sidebar refreshes after association correction

@Suite(
    "MeetingDetailViewModel -- sidebar refresh after association (N2)"
)
struct MeetingDetailSidebarRefreshTests {
    @Test(
        "correctAssociation refreshes sidebar summaries with new title"
    )
    @MainActor
    func sidebarRefreshesAfterAssociation() async throws {
        let dto = makeEventDTO(
            suffix: "n2-side",
            title: "Design Sync",
            location: "https://zoom.us/j/n2",
            calendarTitle: "Team"
        )

        let fix = try makeCoreFixture(
            calendarEventDTOs: [dto],
            calendarRefreshResult: dto,
            testName: "N2Sidebar"
        )
        defer { fix.cleanup() }

        let meetingID = try await fix.store.createMeeting(
            title: "Untitled Meeting"
        )
        await fix.core.reloadSummaries()

        // Sidebar starts with the original title
        #expect(
            fix.core.summaries.first(where: { $0.id == meetingID })?
                .title == "Untitled Meeting"
        )

        let viewModel = MeetingDetailViewModel(
            core: fix.core,
            meetingID: meetingID,
            makePlayer: { G3aFakePlayer() }
        )
        await viewModel.load()

        // Associate the event
        await viewModel.loadNearbyEvents()
        guard let eventKey = viewModel.availableEvents.first?.id else {
            Issue.record("Expected at least one nearby event")
            return
        }
        await viewModel.correctAssociation(eventKey: eventKey)

        // Detail shows the new title
        #expect(viewModel.detail?.title == "Design Sync")

        // Sidebar must also reflect the new title (N2 fix).
        // NOTE: removeAssociation() delegates to correctAssociation(eventKey: nil),
        // so the unlink path shares this same reloadSummaries call and is covered
        // by delegation without a separate test.
        #expect(
            fix.core.summaries.first(where: { $0.id == meetingID })?
                .title == "Design Sync"
        )
    }
}

// MARK: - G3aFakePlayer

/// Minimal fake player for G3a tests. Uses a distinct name to avoid
/// conflict with the FakeAudioPlayer in MeetingDetailPhase8Tests.
private final class G3aFakePlayer: AudioPlaybackProviding,
    @unchecked Sendable
{
    var isPlaying: Bool = false
    var currentTime: TimeInterval = 0
    var duration: TimeInterval = 120
    var rate: Float = 1.0

    func play() {
        isPlaying = true
    }

    func pause() {
        isPlaying = false
    }

    func load(urls _: [URL]) throws {}
}
