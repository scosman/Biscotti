import AppLinks
import AudioCapture
import BiscottiTestSupport
import Calendar
import DataStore
import Foundation
import Testing
@testable import AppCore

// MARK: - App-link apply tests

/// Behavior tests for `AppCore.apply(_:)` — one fixture per documented
/// route, the two existence-failure alerts, the onboarding drop, and the
/// record rules. URL *parsing* itself is covered by `AppLinksTests`.
@Suite("AppCore -- app link apply")
struct AppLinkApplyTests {
    // MARK: - Simple routes

    @Test("home link routes to Home")
    @MainActor
    func homeLinkRoutesHome() async throws {
        let fix = try makeCoreFixture(testName: "AppLinkApply")
        defer { fix.cleanup() }

        fix.core.showSettings()
        await fix.core.apply(.home)

        #expect(fix.core.route == .home)
    }

    @Test("meetings link clears search and keeps selection")
    @MainActor
    func meetingsLinkClearsSearchKeepsSelection() async throws {
        let fix = try makeCoreFixture(testName: "AppLinkApply")
        defer { fix.cleanup() }

        let meetingID = try await fix.store.createMeeting(title: "Kept")
        fix.core.select(meetingID)
        fix.core.setMeetingsQuery("anything")

        await fix.core.apply(.meetings)

        #expect(fix.core.route == .meetings)
        #expect(fix.core.meetingsQuery == "")
        #expect(fix.core.meetingsResults == [])
        #expect(fix.core.meetingsSelection == [meetingID])
    }

    @Test("settings link routes to Settings")
    @MainActor
    func settingsLinkRoutesSettings() async throws {
        let fix = try makeCoreFixture(testName: "AppLinkApply")
        defer { fix.cleanup() }

        await fix.core.apply(.settings)

        #expect(fix.core.route == .settings)
    }

    // MARK: - Meeting route

    @Test("meeting link selects the meeting and sets a transcript-time intent")
    @MainActor
    func meetingLinkSetsIntent() async throws {
        let fix = try makeCoreFixture(testName: "AppLinkApply")
        defer { fix.cleanup() }

        let meetingID = try await fix.store.createMeeting(title: "Target")

        await fix.core.apply(
            .meeting(id: meetingID, target: .transcriptTime(42))
        )

        #expect(fix.core.route == .meetings)
        #expect(fix.core.meetingsSelection == [meetingID])
        #expect(fix.core.pendingMeetingIntent?.meetingID == meetingID)
        #expect(fix.core.pendingMeetingIntent?.target == .transcriptTime(42))
    }

    @Test("meeting link with no time or tab opens on Summary (was a no-op)")
    @MainActor
    func meetingLinkWithoutTimeOpensOnSummary() async throws {
        let fix = try makeCoreFixture(testName: "AppLinkApply")
        defer { fix.cleanup() }

        let meetingID = try await fix.store.createMeeting(title: "Default Tab")

        // The URL shape that used to be a no-op now resolves via parsing.
        let url = try #require(URL(
            string: "biscotti://meeting/\(meetingID.uuidString)"
        ))
        let link = try #require(AppLink(url: url))
        await fix.core.apply(link)

        #expect(fix.core.route == .meetings)
        #expect(fix.core.meetingsSelection == [meetingID])
        #expect(fix.core.pendingMeetingIntent?.target == .tab(.summary))
    }

    @Test("tab and time conflict: time wins (parsed end to end)")
    @MainActor
    func tabTimeConflictPrefersTime() async throws {
        let fix = try makeCoreFixture(testName: "AppLinkApply")
        defer { fix.cleanup() }

        let meetingID = try await fix.store.createMeeting(title: "Conflict")
        let url = try #require(URL(
            string:
            "biscotti://meeting/\(meetingID.uuidString)?tab=notes&time=42"
        ))
        try await fix.core.apply(#require(AppLink(url: url)))

        #expect(
            fix.core.pendingMeetingIntent?.target == .transcriptTime(42)
        )
    }

    @Test("tab-only link carries the tab")
    @MainActor
    func tabOnlyLinkCarriesTab() async throws {
        let fix = try makeCoreFixture(testName: "AppLinkApply")
        defer { fix.cleanup() }

        let meetingID = try await fix.store.createMeeting(title: "Tab Only")

        await fix.core.apply(
            .meeting(id: meetingID, target: .tab(.notes))
        )

        #expect(fix.core.pendingMeetingIntent?.target == .tab(.notes))
    }

    @Test("nonexistent meeting sets meetingNotFound and leaves route untouched")
    @MainActor
    func nonexistentMeetingSetsLinkError() async throws {
        let fix = try makeCoreFixture(testName: "AppLinkApply")
        defer { fix.cleanup() }

        fix.core.showSettings()
        await fix.core.apply(.meeting(id: UUID(), target: .tab(.summary)))

        #expect(fix.core.linkError == .meetingNotFound)
        #expect(fix.core.route == .settings)
        #expect(fix.core.meetingsSelection == [])
        #expect(fix.core.pendingMeetingIntent == nil)
    }

    @Test("repeated identical meeting links produce distinct tokens")
    @MainActor
    func repeatedIdenticalLinksProduceDistinctTokens() async throws {
        let fix = try makeCoreFixture(testName: "AppLinkApply")
        defer { fix.cleanup() }

        let meetingID = try await fix.store.createMeeting(title: "Repeat")
        let link = AppLink.meeting(id: meetingID, target: .tab(.notes))

        await fix.core.apply(link)
        let first = try #require(fix.core.pendingMeetingIntent)
        await fix.core.apply(link)
        let second = try #require(fix.core.pendingMeetingIntent)

        #expect(first != second)
        #expect(first.token != second.token)
    }

    @Test("consumeMeetingIntent clears the pending intent")
    @MainActor
    func consumeClearsPendingIntent() async throws {
        let fix = try makeCoreFixture(testName: "AppLinkApply")
        defer { fix.cleanup() }

        let meetingID = try await fix.store.createMeeting(title: "Consume")
        await fix.core.apply(.meeting(id: meetingID, target: .tab(.summary)))
        #expect(fix.core.pendingMeetingIntent != nil)

        fix.core.consumeMeetingIntent()
        #expect(fix.core.pendingMeetingIntent == nil)
    }

    // MARK: - Search route

    @Test("search link sets the query and focuses the field")
    @MainActor
    func searchLinkSetsQueryAndFocuses() async throws {
        let fix = try makeCoreFixture(testName: "AppLinkApply")
        defer { fix.cleanup() }

        let tokenBefore = fix.core.searchFocusToken
        await fix.core.apply(.search(query: "standup"))

        #expect(fix.core.route == .meetings)
        #expect(fix.core.meetingsQuery == "standup")
        #expect(fix.core.searchFocusToken == tokenBefore + 1)
    }

    @Test("search link with empty query is browse mode plus focus")
    @MainActor
    func emptySearchQueryIsOpenSearch() async throws {
        let fix = try makeCoreFixture(testName: "AppLinkApply")
        defer { fix.cleanup() }

        await fix.core.apply(.search(query: ""))

        #expect(fix.core.route == .meetings)
        #expect(fix.core.meetingsQuery == "")
        #expect(fix.core.searchFocusToken == 1)
    }

    // MARK: - Upcoming route

    @Test("upcoming link with a live key routes to the event preview")
    @MainActor
    func upcomingLinkRoutesToEvent() async throws {
        let fix = try makeCoreFixture(
            calendarEventDTOs: [makeUpcomingDTO()],
            testName: "AppLinkApply"
        )
        defer { fix.cleanup() }

        let window = DateInterval(
            start: Date().addingTimeInterval(-3600),
            end: Date().addingTimeInterval(24 * 3600)
        )
        await fix.calendarService.refreshUpcoming(window: window)
        let key = try #require(fix.calendarService.upcoming.first?.id)

        await fix.core.apply(.upcoming(key: key))

        #expect(fix.core.route == .event(key))
        #expect(fix.core.linkError == nil)
    }

    @Test("upcoming link with an unknown key sets eventNotFound")
    @MainActor
    func unknownUpcomingKeySetsLinkError() async throws {
        let fix = try makeCoreFixture(testName: "AppLinkApply")
        defer { fix.cleanup() }

        fix.core.showHome()
        await fix.core.apply(
            .upcoming(key: "eventID|itemID|9999999999")
        )

        #expect(fix.core.linkError == .eventNotFound)
        #expect(fix.core.route == .home)
    }

    // MARK: - Link errors

    @Test("dismissLinkError clears the error")
    @MainActor
    func dismissClearsLinkError() async throws {
        let fix = try makeCoreFixture(testName: "AppLinkApply")
        defer { fix.cleanup() }

        await fix.core.apply(.meeting(id: UUID(), target: .tab(.summary)))
        #expect(fix.core.linkError == .meetingNotFound)

        fix.core.dismissLinkError()
        #expect(fix.core.linkError == nil)
    }

    @Test("a second failure replaces the first")
    @MainActor
    func secondFailureReplacesFirst() async throws {
        let fix = try makeCoreFixture(testName: "AppLinkApply")
        defer { fix.cleanup() }

        await fix.core.apply(.meeting(id: UUID(), target: .tab(.summary)))
        #expect(fix.core.linkError == .meetingNotFound)

        await fix.core.apply(.upcoming(key: "missing"))
        #expect(fix.core.linkError == .eventNotFound)
    }

    // MARK: - Onboarding drop (R6)

    @Test("links are dropped while onboarding is active")
    @MainActor
    func onboardingDropsLinks() async throws {
        let fix = try makeCoreFixture(testName: "AppLinkApply")
        defer { fix.cleanup() }

        let meetingID = try await fix.store.createMeeting(title: "Onboarding")
        fix.core.showOnboardingReplay()

        await fix.core.apply(.home)
        await fix.core.apply(.settings)
        await fix.core.apply(
            .meeting(id: meetingID, target: .transcriptTime(10))
        )
        await fix.core.apply(.record(title: nil))

        #expect(fix.core.route == .onboarding)
        #expect(fix.core.pendingMeetingIntent == nil)
        #expect(fix.core.recording.state.isRecording == false)
    }
}

/// The `record` route's behavior: default and titled starts, and the
/// already-recording redirect to the recording pane.
@Suite("AppCore -- app link record")
struct AppLinkRecordTests {
    // MARK: - Record route

    @Test("record link starts a recording with the default title")
    @MainActor
    func recordLinkStartsRecording() async throws {
        let fix = try makeCoreFixture(testName: "AppLinkApply")
        defer { fix.cleanup() }

        await fix.core.apply(.record(title: nil))

        #expect(fix.core.route == .recording)
        #expect(fix.core.recording.state.isRecording == true)
        let meetingID = try #require(fix.core.recording.state.meetingID)
        try await fix.store.read { store in
            let meeting = try #require(try store.meeting(id: meetingID))
            #expect(meeting.title == "Untitled Meeting")
        }
    }

    @Test("record link with a title passes the title to the store")
    @MainActor
    func recordLinkWithTitleReachesStore() async throws {
        let fix = try makeCoreFixture(testName: "AppLinkApply")
        defer { fix.cleanup() }

        await fix.core.apply(.record(title: "Url-Started Recording"))

        let meetingID = try #require(fix.core.recording.state.meetingID)
        try await fix.store.read { store in
            let meeting = try #require(try store.meeting(id: meetingID))
            #expect(meeting.title == "Url-Started Recording")
            // Marked edited, so a calendar match cannot overwrite it:
            // `applyEventTitle` guards only on this flag, and every
            // recording start runs `calendar.bestMatch`.
            #expect(meeting.editedTitle)
        }
    }

    @Test("a calendar event title cannot overwrite a record link's title")
    @MainActor
    func recordLinkTitleSurvivesEventTitle() async throws {
        let fix = try makeCoreFixture(testName: "AppLinkApply")
        defer { fix.cleanup() }

        await fix.core.apply(.record(title: "Url-Started Recording"))
        let meetingID = try #require(fix.core.recording.state.meetingID)

        // The association path an auto-matched calendar event would take.
        try await fix.store.applyEventTitle("Weekly Sync", for: meetingID)

        try await fix.store.read { store in
            let meeting = try #require(try store.meeting(id: meetingID))
            #expect(meeting.title == "Url-Started Recording")
        }
    }

    @Test("a default-titled recording still accepts a calendar event title")
    @MainActor
    func defaultTitleStillTakesEventTitle() async throws {
        let fix = try makeCoreFixture(testName: "AppLinkApply")
        defer { fix.cleanup() }

        await fix.core.apply(.record(title: nil))
        let meetingID = try #require(fix.core.recording.state.meetingID)

        try await fix.store.applyEventTitle("Weekly Sync", for: meetingID)

        try await fix.store.read { store in
            let meeting = try #require(try store.meeting(id: meetingID))
            #expect(meeting.title == "Weekly Sync")
        }
    }

    @Test("record link while recording routes to the pane, no second session")
    @MainActor
    func recordWhileRecordingShowsPane() async throws {
        let fix = try makeCoreFixture(testName: "AppLinkApply")
        defer { fix.cleanup() }

        await fix.core.apply(.record(title: nil))
        let firstMeetingID = try #require(
            fix.core.recording.state.meetingID
        )

        fix.core.showHome()
        await fix.core.apply(.record(title: "Second Try"))

        #expect(fix.core.route == .recording)
        #expect(fix.core.recording.state.meetingID == firstMeetingID)
        try await fix.store.read { store in
            let meeting = try #require(
                try store.meeting(id: firstMeetingID)
            )
            #expect(meeting.title == "Untitled Meeting")
        }
    }

    @Test("record link while startup failed routes to the pane, no restart")
    @MainActor
    func recordWhileStartupFailedShowsPane() async throws {
        let fix = try makeCoreFixture(
            startError: CaptureError.micEngineFailed("boom"),
            testName: "AppLinkApply"
        )
        defer { fix.cleanup() }

        // First attempt fails; the pane shows the failed state. Await the
        // controller's async cleanup of the failed meeting before reading
        // the store.
        await fix.core.apply(.record(title: nil))
        await fix.core.recording.awaitPendingCleanup()
        guard case .failed = fix.core.recordingStartup else {
            Issue.record("expected failed startup, got \(String(describing: fix.core.recordingStartup))")
            return
        }

        // A restart would now succeed, so the assertions below prove the
        // URL did not re-enter startup (the guard routed instead).
        fix.fakeRecorder.backing.startError = nil

        await fix.core.apply(.record(title: "Restart Attempt"))

        #expect(fix.core.route == .recording)
        #expect(fix.core.recording.state.isRecording == false)
        guard case .failed = fix.core.recordingStartup else {
            Issue.record("expected startup to stay failed, got \(String(describing: fix.core.recordingStartup))")
            return
        }
        let summaries = try await fix.store.meetingSummaries()
        #expect(summaries.isEmpty)
    }

    // MARK: - Copy Meeting Link

    @Test("copyMeetingLink hands the canonical Summary link to the writer")
    @MainActor
    func copyMeetingLinkWritesCanonicalURL() async throws {
        let fix = try makeCoreFixture(testName: "AppLinkApply")
        defer { fix.cleanup() }

        let meetingID = try await fix.store.createMeeting(title: "Linked")
        var written: [String] = []
        fix.core.copyMeetingLink(meetingID) { written.append($0) }

        // Default (Summary) target, so no query parameters — matching the
        // MCP `app_url` and the copied menu-item link.
        #expect(written == ["biscotti://meeting/\(meetingID.uuidString)"])
    }
}

// MARK: - Helpers

private func makeUpcomingDTO() -> EKEventDTO {
    let start = Date().addingTimeInterval(3600)
    return EKEventDTO(
        eventIdentifier: "ev-upcoming",
        calendarItemIdentifier: "ci-upcoming",
        calendarItemExternalIdentifier: "ext-upcoming",
        occurrenceDate: start,
        title: "Upcoming Sync",
        startDate: start,
        endDate: start.addingTimeInterval(1800),
        isAllDay: false,
        location: "https://zoom.us/j/999",
        url: nil,
        timeZone: nil,
        notes: nil,
        status: nil,
        availability: nil,
        calendarIdentifier: "cal-1",
        calendarTitle: "Work",
        calendarColorHex: "#0066CC",
        calendarSourceTitle: "iCloud",
        birthdayContactIdentifier: nil,
        attendeeCount: 3,
        attendees: [],
        organizer: nil
    )
}
