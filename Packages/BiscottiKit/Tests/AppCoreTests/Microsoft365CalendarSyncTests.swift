import BiscottiTestSupport
import Calendar
import DataStore
import Foundation
import GraphAuth
import GraphCalendar
import Intelligence
import Testing
import Transcription
@testable import AppCore

// MARK: - Microsoft 365 calendar sync (o365_calendar Phase 3)

@Suite("AppCore -- Microsoft 365 calendars")
@MainActor
struct Microsoft365CalendarSyncTests {
    private typealias Harness = Microsoft365CalendarHarness

    /// Now to the whole second, as Graph's `dateTime`.
    private static func wholeSecond(_ offset: TimeInterval = 0) -> Date {
        Date(timeIntervalSince1970: (Date().timeIntervalSince1970 + offset).rounded(.down))
    }

    private static func meeting(
        _ id: String,
        _ subject: String,
        startsIn offset: TimeInterval,
        organizer: StubGraphTenant.Person? = nil,
        attendees: [StubGraphTenant.Person] = []
    ) -> StubGraphTenant.Event {
        let start = wholeSecond(offset)
        return StubGraphTenant.Event(
            id: id,
            subject: subject,
            start: start,
            end: start.addingTimeInterval(1800),
            joinURL: "https://teams.microsoft.com/l/meetup-join/\(id)",
            organizer: organizer,
            attendees: attendees
        )
    }

    @Test("signed in: the calendars are authorized and upcoming shows the account's meetings")
    func signedInFillsUpcoming() async throws {
        let harness = try await Harness(tenant: StubGraphTenant(events: [Self.meeting("evt-review", "Design review", startsIn: 3600)]), testName: "AppCoreTests")
        defer { harness.fix.cleanup() }

        #expect(harness.sync.store.authorizationStatus() == .authorized)
        #expect(harness.sync.lastSynced != nil)
        #expect(harness.sync.syncErrorMessage == nil)
        #expect(await harness.fix.core.calendar.calendars().map(\.id) == [StubGraphTenant.defaultCalendarID])

        await refreshUpcoming(harness)
        #expect(harness.fix.core.calendar.auth == .authorized)
        #expect(harness.fix.core.calendar.upcoming.map(\.title) == ["Design review"])
        #expect(harness.fix.core.calendar.upcoming.first?.conferencePlatform != nil)
    }

    @Test("signing out drops the events and the access")
    func signOutClears() async throws {
        let harness = try await Harness(tenant: StubGraphTenant(events: [Self.meeting("evt-review", "Design review", startsIn: 3600)]), testName: "AppCoreTests")
        defer { harness.fix.cleanup() }

        await harness.account.controller.signOut()
        await harness.sync.refresh()

        #expect(harness.sync.store.authorizationStatus() == .notDetermined)
        #expect(harness.sync.store.snapshot == nil)
        #expect(harness.sync.lastSynced == nil)
        await refreshUpcoming(harness)
        #expect(harness.fix.core.calendar.auth == .notDetermined)
        #expect(harness.fix.core.calendar.upcoming.isEmpty)
    }

    @Test("a new account starts with every calendar enabled")
    func selectionResetForNewAccount() async throws {
        let defaults = Microsoft365Fixture.scratchDefaults()
        let harness = try await Harness(defaults: defaults, testName: "AppCoreTests") { store in
            // EventKit's selection would hide every Graph calendar.
            try await store.updateSettings { $0.enabledCalendarIDs = ["ek-calendar"] }
        }
        defer { harness.fix.cleanup() }

        #expect(try await harness.fix.store.settings().enabledCalendarIDs == nil)
        #expect(
            defaults.string(forKey: Microsoft365CalendarSync.selectionAccountKey)
                == Microsoft365Fixture.account.objectID
        )
    }

    @Test("the same account keeps its calendar selection")
    func selectionKeptForSameAccount() async throws {
        let defaults = Microsoft365Fixture.scratchDefaults()
        defaults.set(Microsoft365Fixture.account.objectID, forKey: Microsoft365CalendarSync.selectionAccountKey)
        let harness = try await Harness(defaults: defaults, testName: "AppCoreTests") { store in
            try await store.updateSettings { $0.enabledCalendarIDs = [StubGraphTenant.defaultCalendarID] }
        }
        defer { harness.fix.cleanup() }

        #expect(try await harness.fix.store.settings().enabledCalendarIDs == [StubGraphTenant.defaultCalendarID])
    }

    @Test("offline: the last sync's meetings stay, with a message for Settings")
    func offlineKeepsSnapshot() async throws {
        let harness = try await Harness(tenant: StubGraphTenant(events: [Self.meeting("evt-review", "Design review", startsIn: 3600)]), testName: "AppCoreTests")
        defer { harness.fix.cleanup() }
        let synced = harness.sync.lastSynced

        await harness.tenant.setOffline(true)
        await harness.sync.refresh()

        #expect(harness.sync.syncErrorMessage == "Couldn't reach Microsoft 365. Showing meetings from the last sync.")
        #expect(harness.sync.lastSynced == synced)
        #expect(harness.sync.store.isStale)
        await refreshUpcoming(harness)
        #expect(harness.fix.core.calendar.upcoming.map(\.title) == ["Design review"])

        await harness.tenant.setOffline(false)
        await harness.sync.refresh()
        #expect(harness.sync.syncErrorMessage == nil)
    }

    @Test("the picker reads the events around an older recording")
    func pickerReadsOlderEvents() async throws {
        let date = Self.wholeSecond(-10 * 24 * 3600)
        let older = StubGraphTenant.Event(
            id: "evt-old",
            subject: "Kickoff",
            start: date,
            end: date.addingTimeInterval(3600),
            joinURL: "https://teams.microsoft.com/l/meetup-join/old"
        )
        let harness = try await Harness(tenant: StubGraphTenant(events: [older]), testName: "AppCoreTests")
        defer { harness.fix.cleanup() }

        let events = await harness.fix.core.eventsNear(date)

        #expect(events.map(\.title) == ["Kickoff"])
        let radius = GraphCalendarPoller.nearbyRadius
        let window = DateInterval(start: date.addingTimeInterval(-radius), end: date.addingTimeInterval(radius))
        #expect(await harness.tenant.calendarViewWindows.contains(window))
    }

    /// The attendee emails Microsoft 365 returns reach the speaker-naming
    /// prompt and the voiceprint matcher's invitee boost.
    @Test("a linked Microsoft 365 event's invitee emails reach speaker naming")
    func inviteeEmailsReachSpeakerNaming() async throws {
        let sam = StubGraphTenant.Person("Sam Park", "Sam.Park@contoso.com")
        let pat = StubGraphTenant.Person("Pat Lee", "pat.lee@contoso.com")
        let event = Self.meeting("evt-sync", "Weekly sync", startsIn: -2 * 3600, organizer: sam, attendees: [sam, pat])
        let harness = try await Harness(tenant: StubGraphTenant(events: [event]), testName: "AppCoreTests")
        defer { harness.fix.cleanup() }
        let store = harness.fix.store
        let meetingID = try await store.createMeeting(title: "Recording")
        let transcriptID = try await store.addTranscript(
            Self.twoSpeakerTranscript(),
            vocabularyUsed: [],
            mappedEventIdentifier: nil,
            to: meetingID
        )
        try await store.setPreferredTranscript(transcriptID, for: meetingID)

        let candidates = await harness.fix.core.eventsNear(event.start)
        let key = try #require(candidates.first { $0.title == "Weekly sync" }?.id)
        await harness.fix.core.correctAssociation(meetingID: meetingID, eventKey: key)

        let detail = try #require(try await store.meetingDetail(id: meetingID))
        #expect(detail.calendar?.title == "Weekly sync")
        let block = IntelligencePrompts.meetingDetailsBlock(detail)
        #expect(block.contains("Sam Park <Sam.Park@contoso.com>"))
        #expect(block.contains("Pat Lee <pat.lee@contoso.com>"))

        let transcript = try #require(detail.preferredTranscript)
        let evidence = try await VoiceprintEvidence.compute(
            store: store,
            meetingID: meetingID,
            transcript: transcript,
            detail: detail,
            human: [:]
        )
        #expect(evidence.invitees.emails.isSuperset(of: ["sam.park@contoso.com", "pat.lee@contoso.com"]))
    }

    private func refreshUpcoming(_ harness: Harness) async {
        let now = Date()
        await harness.fix.core.calendar.refreshUpcoming(
            window: DateInterval(start: now, duration: CalendarService.upcomingWindowSeconds)
        )
    }

    private static func twoSpeakerTranscript() -> TranscriptResult {
        TranscriptResult(
            transcriptionMethodId: "v1",
            language: "en",
            speakerCount: 2,
            segments: [
                TranscriptSegment(
                    speakerID: 0, speakerLabel: "Speaker 0", startTime: 0, endTime: 5,
                    text: "Morning all", confidence: 0.9, noSpeechProbability: 0.1, words: nil
                ),
                TranscriptSegment(
                    speakerID: 1, speakerLabel: "Speaker 1", startTime: 5, endTime: 10,
                    text: "Morning", confidence: 0.9, noSpeechProbability: 0.1, words: nil
                )
            ],
            processingDuration: 1
        )
    }
}
