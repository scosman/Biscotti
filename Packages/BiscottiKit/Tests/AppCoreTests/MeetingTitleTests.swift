import BiscottiTestSupport
import Calendar
import DataStore
import Foundation
import Recording
import Testing
@testable import AppCore
@testable import MeetingDetailUI

// MARK: - Meeting title system tests (B1)

@Suite("Meeting title system -- default, association, editedTitle")
struct MeetingTitleSystemTests {
    // MARK: - Default title

    @Test("New recording has title 'Untitled Meeting' and editedTitle false")
    @MainActor
    func newRecordingDefaultTitle() async throws {
        let fix = try makeCoreFixture(testName: "MeetingTitle")
        defer { fix.cleanup() }

        await fix.core.startRecording()

        let meetingID = try #require(fix.core.recording.state.meetingID)
        let meeting = try #require(try await fix.store.meeting(id: meetingID))

        #expect(meeting.title == "Untitled Meeting")
        #expect(meeting.editedTitle == false)
    }

    // MARK: - Association applies event title

    @Test("Association applies event title when editedTitle is false")
    @MainActor
    func associationAppliesEventTitle() async throws {
        let now = Date()
        let dto = makeMeetingDTO(
            title: "Team Standup",
            start: now.addingTimeInterval(-300),
            end: now.addingTimeInterval(1500)
        )

        let fix = try makeCoreFixture(
            calendarEventDTOs: [dto],
            calendarRefreshResult: dto,
            testName: "MeetingTitle"
        )
        defer { fix.cleanup() }

        try await fix.store.updateSettings { $0.onboardingComplete = true }
        await fix.core.onLaunch()

        await fix.core.startRecording()

        let meetingID = try #require(fix.core.recording.state.meetingID)
        let meeting = try #require(try await fix.store.meeting(id: meetingID))

        // The event title should have been applied to the meeting
        #expect(meeting.title == "Team Standup")
        #expect(meeting.editedTitle == false)
    }

    // MARK: - Manual edit sets editedTitle

    @Test("Manual edit sets title and editedTitle to true")
    @MainActor
    func manualEditSetsEditedTitle() async throws {
        let fix = try makeCoreFixture(testName: "MeetingTitle")
        defer { fix.cleanup() }

        let meetingID = try await fix.store.createMeeting(
            title: "Untitled Meeting"
        )

        let viewModel = MeetingDetailViewModel(
            core: fix.core,
            meetingID: meetingID,
            makePlayer: { FakeTitlePlayer() }
        )
        await viewModel.load()

        viewModel.editableTitle = "My Custom Title"
        await viewModel.saveTitle()

        let meeting = try #require(try await fix.store.meeting(id: meetingID))
        #expect(meeting.title == "My Custom Title")
        #expect(meeting.editedTitle == true)
    }

    // MARK: - Association does NOT overwrite user-edited title

    @Test("After manual edit, association does NOT overwrite the title")
    @MainActor
    func associationRespectsEditedTitle() async throws {
        let now = Date()
        let dto = makeMeetingDTO(
            eventIdentifier: "ev-post-edit",
            title: "Sprint Planning",
            start: now.addingTimeInterval(-300),
            end: now.addingTimeInterval(1500)
        )

        let fix = try makeCoreFixture(
            calendarEventDTOs: [dto],
            calendarRefreshResult: dto,
            testName: "MeetingTitle"
        )
        defer { fix.cleanup() }

        try await fix.store.updateSettings { $0.onboardingComplete = true }
        await fix.core.onLaunch()

        // Create meeting and mark it as user-edited
        let meetingID = try await fix.store.createMeeting(
            title: "My Custom Title"
        )
        try await fix.store.setTitle(
            "My Custom Title", for: meetingID
        )

        // Verify editedTitle is set
        let meetingBefore = try #require(
            try await fix.store.meeting(id: meetingID)
        )
        #expect(meetingBefore.editedTitle == true)

        // Now associate with an event
        let eventKey = try #require(fix.core.upcoming.first?.id)
        await fix.core.correctAssociation(
            meetingID: meetingID, eventKey: eventKey
        )

        // Title should NOT have changed
        let meetingAfter = try #require(
            try await fix.store.meeting(id: meetingID)
        )
        #expect(meetingAfter.title == "My Custom Title")
        #expect(meetingAfter.editedTitle == true)
    }

    // MARK: - Re-association applies new event title when not edited

    @Test(
        "Re-association to a different event applies new title when not edited"
    )
    @MainActor
    func reAssociationAppliesNewTitle() async throws {
        let now = Date()
        let dto1 = makeMeetingDTO(
            eventIdentifier: "ev-first",
            title: "First Event",
            start: now.addingTimeInterval(-300),
            end: now.addingTimeInterval(1500)
        )
        let dto2 = makeMeetingDTO(
            eventIdentifier: "ev-second",
            title: "Second Event",
            start: now.addingTimeInterval(600),
            end: now.addingTimeInterval(4200)
        )

        // Start with dto1 as the refresh result so first association uses it
        let fix = try makeCoreFixture(
            calendarEventDTOs: [dto1, dto2],
            calendarRefreshResult: dto1,
            testName: "MeetingTitle"
        )
        defer { fix.cleanup() }

        try await fix.store.updateSettings { $0.onboardingComplete = true }
        await fix.core.onLaunch()

        // Create and associate with first event
        let meetingID = try await fix.store.createMeeting(
            title: "Untitled Meeting"
        )
        let firstEventKey = try #require(
            fix.core.upcoming.first { $0.title == "First Event" }?.id
        )
        await fix.core.correctAssociation(
            meetingID: meetingID, eventKey: firstEventKey
        )

        let meetingAfterFirst = try #require(
            try await fix.store.meeting(id: meetingID)
        )
        #expect(meetingAfterFirst.title == "First Event")
        #expect(meetingAfterFirst.editedTitle == false)

        // Now re-associate with the second event
        fix.fakeEventStore.refreshResult = dto2
        let secondEventKey = try #require(
            fix.core.upcoming.first { $0.title == "Second Event" }?.id
        )
        await fix.core.correctAssociation(
            meetingID: meetingID, eventKey: secondEventKey
        )

        let meetingAfterSecond = try #require(
            try await fix.store.meeting(id: meetingID)
        )
        #expect(meetingAfterSecond.title == "Second Event")
        #expect(meetingAfterSecond.editedTitle == false)
    }

    // MARK: - Migration: existing meetings default editedTitle to false

    @Test("Existing meetings load with editedTitle defaulting to false")
    @MainActor
    func existingMeetingsDefaultEditedTitleFalse() async throws {
        let fix = try makeCoreFixture(testName: "MeetingTitle")
        defer { fix.cleanup() }

        // Create a meeting the "old" way (without explicitly setting editedTitle)
        let meetingID = try await fix.store.createMeeting(title: "Legacy Meeting")
        let meeting = try #require(try await fix.store.meeting(id: meetingID))

        // editedTitle should default to false (additive property with default)
        #expect(meeting.editedTitle == false)
    }

    // MARK: - Join-button bug fix verification

    @Test(
        "Recording started from Join button applies event title (bug fix)"
    )
    @MainActor
    func joinButtonRecordingAppliesEventTitle() async throws {
        let now = Date()
        let dto = makeMeetingDTO(
            title: "Weekly Sync",
            start: now.addingTimeInterval(-300),
            end: now.addingTimeInterval(1500)
        )

        let fix = try makeCoreFixture(
            calendarEventDTOs: [dto],
            calendarRefreshResult: dto,
            testName: "MeetingTitle"
        )
        defer { fix.cleanup() }

        try await fix.store.updateSettings { $0.onboardingComplete = true }
        await fix.core.onLaunch()

        let eventKey = try #require(fix.core.upcoming.first?.id)

        // Simulate the Join-and-Record flow
        await fix.core.startRecording(eventKey: eventKey)

        let meetingID = try #require(fix.core.recording.state.meetingID)
        let meeting = try #require(try await fix.store.meeting(id: meetingID))

        // The title should be the event title, NOT "Untitled Meeting"
        #expect(meeting.title == "Weekly Sync")
        #expect(meeting.editedTitle == false)

        // Verify via the detail DTO as well
        let detail = try await fix.store.meetingDetail(id: meetingID)
        #expect(detail?.title == "Weekly Sync")
    }

    // MARK: - DataStore applyEventTitle unit tests

    @Test("applyEventTitle updates title when editedTitle is false")
    @MainActor
    func applyEventTitleUpdatesWhenNotEdited() async throws {
        let fix = try makeCoreFixture(testName: "MeetingTitle")
        defer { fix.cleanup() }

        let meetingID = try await fix.store.createMeeting(
            title: "Untitled Meeting"
        )
        try await fix.store.applyEventTitle(
            "Design Review", for: meetingID
        )

        let meeting = try #require(try await fix.store.meeting(id: meetingID))
        #expect(meeting.title == "Design Review")
    }

    @Test("applyEventTitle is no-op when editedTitle is true")
    @MainActor
    func applyEventTitleNoOpWhenEdited() async throws {
        let fix = try makeCoreFixture(testName: "MeetingTitle")
        defer { fix.cleanup() }

        let meetingID = try await fix.store.createMeeting(
            title: "Custom Name"
        )
        // Mark as user-edited
        try await fix.store.setTitle("Custom Name", for: meetingID)

        // Try to apply event title -- should be ignored
        try await fix.store.applyEventTitle(
            "Sprint Planning", for: meetingID
        )

        let meeting = try #require(try await fix.store.meeting(id: meetingID))
        #expect(meeting.title == "Custom Name")
        #expect(meeting.editedTitle == true)
    }

    @Test("setTitle sets editedTitle to true")
    @MainActor
    func setTitleSetsEditedFlag() async throws {
        let fix = try makeCoreFixture(testName: "MeetingTitle")
        defer { fix.cleanup() }

        let meetingID = try await fix.store.createMeeting(
            title: "Untitled Meeting"
        )
        let meetingBefore = try #require(
            try await fix.store.meeting(id: meetingID)
        )
        #expect(meetingBefore.editedTitle == false)

        try await fix.store.setTitle("My Title", for: meetingID)

        let meetingAfter = try #require(
            try await fix.store.meeting(id: meetingID)
        )
        #expect(meetingAfter.title == "My Title")
        #expect(meetingAfter.editedTitle == true)
    }
}

// MARK: - Helpers

private func makeMeetingDTO(
    eventIdentifier: String = "ev-1",
    title: String = "Standup",
    start: Date,
    end: Date,
    attendeeCount: Int = 3,
    calendarTitle: String = "Work",
    location: String? = "https://zoom.us/j/123"
) -> EKEventDTO {
    EKEventDTO(
        eventIdentifier: eventIdentifier,
        calendarItemIdentifier: "ci-\(eventIdentifier)",
        calendarItemExternalIdentifier: "ext-\(eventIdentifier)",
        occurrenceDate: start,
        title: title,
        startDate: start,
        endDate: end,
        isAllDay: false,
        location: location,
        url: nil,
        timeZone: nil,
        notes: nil,
        status: nil,
        availability: nil,
        calendarIdentifier: "cal-1",
        calendarTitle: calendarTitle,
        calendarColorHex: "#0066CC",
        calendarSourceTitle: "iCloud",
        birthdayContactIdentifier: nil,
        attendeeCount: attendeeCount,
        attendees: [],
        organizer: nil
    )
}

/// Minimal fake player for title tests.
private final class FakeTitlePlayer: AudioPlaybackProviding,
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

    func load(urls _: [URL]) throws {}
}
