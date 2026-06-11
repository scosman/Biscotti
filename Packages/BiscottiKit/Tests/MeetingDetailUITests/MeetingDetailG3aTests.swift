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

    @Test("flushNotes also saves pending title")
    @MainActor
    func flushNotesSavesPendingTitle() async throws {
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
        await viewModel.flushNotes()

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
        #expect(title == "Recording")
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
        "single VM: associate event, context appears"
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

        try await fix.store.updateSettings {
            $0.onboardingComplete = true
        }
        await fix.core.onLaunch()

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

        guard let eventKey = fix.core.upcoming.first?.id else {
            Issue.record("Expected at least one upcoming event")
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
            testName: "G3aNoPrompt"
        )
        defer { fix.cleanup() }

        try await fix.store.updateSettings {
            $0.onboardingComplete = true
        }
        await fix.core.onLaunch()

        let meetingID = try await fix.store.createMeeting(
            title: "No Prompt Test"
        )

        let viewModel = MeetingDetailViewModel(
            core: fix.core,
            meetingID: meetingID,
            makePlayer: { G3aFakePlayer() }
        )
        await viewModel.load()

        guard let eventKey = fix.core.upcoming.first?.id else {
            Issue.record("Expected at least one upcoming event")
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

// MARK: - Join button 30-min gating (item 5)

@Suite("MeetingDetailViewModel -- Join button visibility")
struct MeetingDetailJoinButtonTests {
    @Test("showJoinButton false when no conference URL")
    @MainActor
    func joinHiddenWithoutURL() async throws {
        let fix = try makeCoreFixture(testName: "G3aJoin")
        defer { fix.cleanup() }

        let meetingID = try await fix.store.createMeeting(
            title: "No URL Meeting"
        )

        let viewModel = MeetingDetailViewModel(
            core: fix.core,
            meetingID: meetingID,
            makePlayer: { G3aFakePlayer() }
        )
        await viewModel.load()

        #expect(viewModel.showJoinButton == false)
    }

    @Test("showJoinButton true for recent meeting with conference URL")
    @MainActor
    func joinShownForRecentMeeting() async throws {
        let fix = try makeCoreFixture(testName: "G3aJoin")
        defer { fix.cleanup() }

        let now = Date()
        let meetingID = try await fix.store.createMeeting(
            title: "Recent Zoom"
        )
        try await fix.store.setSnapshot(
            makeSnapshot(
                suffix: "join",
                startDate: now.addingTimeInterval(-3600),
                endDate: now.addingTimeInterval(-600),
                conferenceURL: URL(string: "https://zoom.us/j/join"),
                conferencePlatform: "Zoom"
            ),
            for: meetingID
        )

        let viewModel = MeetingDetailViewModel(
            core: fix.core, meetingID: meetingID,
            makePlayer: { G3aFakePlayer() },
            currentDate: { now }
        )
        await viewModel.load()

        #expect(viewModel.showJoinButton == true)
    }

    @Test("showJoinButton false for meeting ended >30 min ago")
    @MainActor
    func joinHiddenForOldMeeting() async throws {
        let fix = try makeCoreFixture(testName: "G3aJoin")
        defer { fix.cleanup() }

        let now = Date()
        let meetingID = try await fix.store.createMeeting(
            title: "Old Zoom"
        )
        try await fix.store.setSnapshot(
            makeSnapshot(
                suffix: "old-join",
                startDate: now.addingTimeInterval(-10800),
                endDate: now.addingTimeInterval(-7200),
                conferenceURL: URL(string: "https://zoom.us/j/old"),
                conferencePlatform: "Zoom"
            ),
            for: meetingID
        )

        let viewModel = MeetingDetailViewModel(
            core: fix.core, meetingID: meetingID,
            makePlayer: { G3aFakePlayer() },
            currentDate: { now }
        )
        await viewModel.load()

        #expect(viewModel.showJoinButton == false)
    }

    @Test("showJoinButton true for in-progress meeting")
    @MainActor
    func joinShownForInProgressMeeting() async throws {
        let fix = try makeCoreFixture(testName: "G3aJoin")
        defer { fix.cleanup() }

        let now = Date()
        let meetingID = try await fix.store.createMeeting(
            title: "In Progress"
        )
        try await fix.store.setSnapshot(
            makeSnapshot(
                suffix: "inprogress",
                startDate: now.addingTimeInterval(-1800),
                endDate: now.addingTimeInterval(1800),
                conferenceURL: URL(string: "https://zoom.us/j/prog"),
                conferencePlatform: "Zoom"
            ),
            for: meetingID
        )

        let viewModel = MeetingDetailViewModel(
            core: fix.core, meetingID: meetingID,
            makePlayer: { G3aFakePlayer() },
            currentDate: { now }
        )
        await viewModel.load()

        #expect(viewModel.showJoinButton == true)
    }

    @Test("showJoinButton false without conference URL even with endDate")
    @MainActor
    func joinHiddenWithoutConferenceURL() async throws {
        let fix = try makeCoreFixture(testName: "G3aJoin")
        defer { fix.cleanup() }

        let now = Date()
        let meetingID = try await fix.store.createMeeting(
            title: "No Snapshot",
            start: now.addingTimeInterval(-7200),
            end: now.addingTimeInterval(-3600)
        )

        let viewModel = MeetingDetailViewModel(
            core: fix.core, meetingID: meetingID,
            makePlayer: { G3aFakePlayer() },
            currentDate: { now }
        )
        await viewModel.load()

        #expect(viewModel.showJoinButton == false)
    }

    @Test("showJoinButton at exactly 30-min boundary")
    @MainActor
    func joinAtExactBoundary() async throws {
        let fix = try makeCoreFixture(testName: "G3aJoin")
        defer { fix.cleanup() }

        let now = Date()
        let endTime = now.addingTimeInterval(-30 * 60)
        let meetingID = try await fix.store.createMeeting(
            title: "Boundary"
        )
        try await fix.store.setSnapshot(
            makeSnapshot(
                suffix: "boundary",
                startDate: endTime.addingTimeInterval(-3600),
                endDate: endTime,
                conferenceURL: URL(string: "https://zoom.us/j/edge"),
                conferencePlatform: "Zoom"
            ),
            for: meetingID
        )

        let viewModel = MeetingDetailViewModel(
            core: fix.core, meetingID: meetingID,
            makePlayer: { G3aFakePlayer() },
            currentDate: { now }
        )
        await viewModel.load()

        // At exactly the boundary, now <= cutoff, so shown
        #expect(viewModel.showJoinButton == true)
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

    func play() {
        isPlaying = true
    }

    func pause() {
        isPlaying = false
    }

    func load(url _: URL) throws {}
}
