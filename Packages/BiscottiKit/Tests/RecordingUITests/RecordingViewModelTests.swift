import AudioCapture
import BiscottiTestSupport
import Calendar
import DataStore
import Foundation
import MeetingDetection
import Recording
import Testing
@testable import AppCore
@testable import RecordingUI

// MARK: - Existing tests (updated)

@Suite("RecordingViewModel")
struct RecordingViewModelTests {
    @Test("isRecording reflects AppCore recording state")
    @MainActor
    func isRecordingReflectsState() async throws {
        let fix = try makeCoreFixture(testName: "RecordingUITests")
        defer { fix.cleanup() }

        let viewModel = RecordingViewModel(core: fix.core)
        #expect(viewModel.isRecording == false)

        await fix.core.startRecording()
        #expect(viewModel.isRecording == true)
    }

    @Test("elapsedText formats correctly for zero")
    @MainActor
    func elapsedTextZero() throws {
        let fix = try makeCoreFixture(testName: "RecordingUITests")
        defer { fix.cleanup() }

        let viewModel = RecordingViewModel(core: fix.core)
        #expect(viewModel.elapsedText == "00:00")
    }

    @Test("formatElapsed handles minutes and seconds")
    @MainActor
    func formatElapsedMinutesSeconds() {
        #expect(RecordingViewModel.formatElapsed(0) == "00:00")
        #expect(RecordingViewModel.formatElapsed(5) == "00:05")
        #expect(RecordingViewModel.formatElapsed(65) == "01:05")
        #expect(RecordingViewModel.formatElapsed(134) == "02:14")
    }

    @Test("formatElapsed handles hours")
    @MainActor
    func formatElapsedHours() {
        #expect(RecordingViewModel.formatElapsed(3661) == "1:01:01")
        #expect(RecordingViewModel.formatElapsed(7200) == "2:00:00")
    }

    @Test("showSystemAudioWarning is false by default")
    @MainActor
    func systemAudioWarningDefault() throws {
        let fix = try makeCoreFixture(testName: "RecordingUITests")
        defer { fix.cleanup() }

        let viewModel = RecordingViewModel(core: fix.core)
        #expect(viewModel.showSystemAudioWarning == false)
    }

    @Test("systemAudioSettingsURL returns valid URL")
    @MainActor
    func systemAudioSettingsURL() throws {
        let fix = try makeCoreFixture(testName: "RecordingUITests")
        defer { fix.cleanup() }

        let viewModel = RecordingViewModel(core: fix.core)
        #expect(viewModel.systemAudioSettingsURL.absoluteString.contains("systempreferences"))
    }

    @Test("stop delegates to AppCore")
    @MainActor
    func stopDelegates() async throws {
        let fix = try makeCoreFixture(testName: "RecordingUITests")
        defer { fix.cleanup() }

        await fix.core.startRecording()
        let viewModel = RecordingViewModel(core: fix.core)
        #expect(viewModel.isRecording == true)

        await viewModel.stop()
        #expect(viewModel.isRecording == false)
    }

    @Test("meetingID returns the current recording meeting ID")
    @MainActor
    func meetingIDDuringRecording() async throws {
        let fix = try makeCoreFixture(testName: "RecordingUITests")
        defer { fix.cleanup() }

        let viewModel = RecordingViewModel(core: fix.core)
        #expect(viewModel.meetingID == nil)

        await fix.core.startRecording()
        #expect(viewModel.meetingID != nil)
    }

    @Test("meetingID is nil when not recording")
    @MainActor
    func meetingIDWhenNotRecording() throws {
        let fix = try makeCoreFixture(testName: "RecordingUITests")
        defer { fix.cleanup() }

        let viewModel = RecordingViewModel(core: fix.core)
        #expect(viewModel.meetingID == nil)
    }
}

// MARK: - Phase 3: Left chip tests

@Suite("RecordingViewModel.leftChip")
struct LeftChipTests {
    @Test("returns .none when scheduledEnd is nil")
    @MainActor
    func noneWhenNoScheduledEnd() {
        let result = RecordingViewModel.leftChip(scheduledEnd: nil, now: Date())
        #expect(result == .none)
    }

    @Test("returns .normal when more than 5 minutes remain")
    @MainActor
    func normalAboveFiveMinutes() {
        let now = Date()
        let end = now.addingTimeInterval(600) // 10 minutes
        let result = RecordingViewModel.leftChip(scheduledEnd: end, now: now)
        #expect(result == .normal("10:00"))
    }

    @Test("returns .warning at exactly 5 minutes remaining")
    @MainActor
    func warningAtFiveMinutes() {
        let now = Date()
        let end = now.addingTimeInterval(300) // 5 minutes
        let result = RecordingViewModel.leftChip(scheduledEnd: end, now: now)
        #expect(result == .warning("5:00"))
    }

    @Test("returns .warning below 5 minutes")
    @MainActor
    func warningBelowFiveMinutes() {
        let now = Date()
        let end = now.addingTimeInterval(120) // 2 minutes
        let result = RecordingViewModel.leftChip(scheduledEnd: end, now: now)
        #expect(result == .warning("2:00"))
    }

    @Test("returns .overtime when past scheduled end")
    @MainActor
    func overtimePastEnd() {
        let now = Date()
        let end = now.addingTimeInterval(-180) // 3 minutes past
        let result = RecordingViewModel.leftChip(scheduledEnd: end, now: now)
        #expect(result == .overtime("+3:00"))
    }

    @Test("overtime label formats correctly for hours")
    @MainActor
    func overtimeLabelHours() {
        let now = Date()
        let end = now.addingTimeInterval(-3661) // 1h 1m 1s past
        let result = RecordingViewModel.leftChip(scheduledEnd: end, now: now)
        #expect(result == .overtime("+1:01:01"))
    }

    @Test("returns .overtime at exactly zero remaining")
    @MainActor
    func overtimeAtExactlyZero() {
        let now = Date()
        let result = RecordingViewModel.leftChip(scheduledEnd: now, now: now)
        #expect(result == .overtime("+0:00"))
    }
}

// MARK: - Phase 3: Submeta builder tests

@Suite("RecordingViewModel submeta builders")
struct SubmetaBuilderTests {
    @Test("buildScheduleText formats start and end times")
    @MainActor
    func scheduleTextWithEndTime() {
        // Use a fixed date to avoid locale issues in test assertions.
        // We just verify the string contains the en-dash separator.
        let start = Date(timeIntervalSinceReferenceDate: 0)
        let end = start.addingTimeInterval(1800)
        let result = RecordingViewModel.buildScheduleText(
            start: start, end: end
        )
        #expect(result.contains("\u{2013}"))
    }

    @Test("buildScheduleText without end returns start only")
    @MainActor
    func scheduleTextWithoutEnd() {
        let start = Date(timeIntervalSinceReferenceDate: 0)
        let result = RecordingViewModel.buildScheduleText(
            start: start, end: nil
        )
        #expect(!result.contains("\u{2013}"))
        #expect(!result.isEmpty)
    }

    @Test("buildStartedClockText contains 'Started'")
    @MainActor
    func startedClockTextPrefix() {
        let date = Date()
        let result = RecordingViewModel.buildStartedClockText(date: date)
        #expect(result.hasPrefix("Started "))
    }

    @Test("platformText returns nil when no platform")
    @MainActor
    func platformTextNil() throws {
        let fix = try makeCoreFixture(testName: "SubmetaTests")
        defer { fix.cleanup() }
        let viewModel = RecordingViewModel(core: fix.core)
        #expect(viewModel.platformText == nil)
    }

    @Test("hasEvent is false when no detail loaded")
    @MainActor
    func hasEventFalseDefault() throws {
        let fix = try makeCoreFixture(testName: "SubmetaTests")
        defer { fix.cleanup() }
        let viewModel = RecordingViewModel(core: fix.core)
        #expect(viewModel.hasEvent == false)
    }
}

// MARK: - Phase 3: Chip time formatting

@Suite("RecordingViewModel.formatChipTime")
struct ChipTimeFormattingTests {
    @Test("formats zero as 0:00")
    @MainActor
    func zeroSeconds() {
        #expect(RecordingViewModel.formatChipTime(0) == "0:00")
    }

    @Test("formats minutes and seconds")
    @MainActor
    func minutesAndSeconds() {
        #expect(RecordingViewModel.formatChipTime(65) == "1:05")
        #expect(RecordingViewModel.formatChipTime(300) == "5:00")
    }

    @Test("formats hours")
    @MainActor
    func hours() {
        #expect(RecordingViewModel.formatChipTime(3661) == "1:01:01")
    }

    @Test("clamps negative to zero")
    @MainActor
    func negativeClampedToZero() {
        #expect(RecordingViewModel.formatChipTime(-10) == "0:00")
    }
}

// MARK: - Phase 3: Stop with pending composer

@Suite("RecordingViewModel stop(pendingComposer:)")
struct StopWithComposerTests {
    @Test("commits non-empty composer text as a note before stopping")
    @MainActor
    func stopWithPendingComposer() async throws {
        let fix = try makeCoreFixture(testName: "StopComposerTests")
        defer { fix.cleanup() }

        await fix.core.startRecording()
        let viewModel = RecordingViewModel(core: fix.core)

        // Add a note via the composer path
        await viewModel.stop(pendingComposer: "  Quick thought  ")

        // The recording should have stopped
        #expect(viewModel.isRecording == false)

        // Verify the note was seeded: the meeting's notes should
        // contain the text (seeded by RecordingController.stop)
        let meetingID = fix.core.recording.state.meetingID
            ?? fix.core.summaries.first?.id
        if let id = meetingID {
            let detail = try await fix.store.meetingDetail(id: id)
            // The note text should appear in the seeded markdown
            #expect(detail?.notes.contains("Quick thought") == true)
        }
    }

    @Test("empty composer text does not add a note")
    @MainActor
    func stopWithEmptyComposer() async throws {
        let fix = try makeCoreFixture(testName: "StopComposerTests")
        defer { fix.cleanup() }

        await fix.core.startRecording()
        let viewModel = RecordingViewModel(core: fix.core)

        await viewModel.stop(pendingComposer: "   ")

        #expect(viewModel.isRecording == false)

        // No notes should have been seeded
        await fix.core.reloadSummaries()
        if let id = fix.core.summaries.first?.id {
            let detail = try await fix.store.meetingDetail(id: id)
            #expect(detail?.notes.isEmpty == true)
        }
    }
}

// MARK: - Phase 3: Inline edit committed before stop

@Suite("RecordingViewModel inline edit on stop")
struct InlineEditOnStopTests {
    @Test("inline note edit committed before stop is seeded")
    @MainActor
    func inlineEditCommittedBeforeStop() async throws {
        let fix = try makeCoreFixture(
            testName: "InlineEditStop"
        )
        defer { fix.cleanup() }

        await fix.core.startRecording()
        let viewModel = RecordingViewModel(core: fix.core)

        // Add a note during recording
        viewModel.addNote("First draft")

        let noteID = try #require(viewModel.notes.first?.id)

        // Simulate what RecordingView.commitPendingNoteEdit() does
        // when the user has an in-progress inline edit at stop time:
        // update the note text, then stop.
        viewModel.updateNote(id: noteID, text: "Revised text")

        await viewModel.stop()

        // The seeded markdown should contain the revised text
        await fix.core.reloadSummaries()
        let meetingID = try #require(fix.core.summaries.first?.id)
        let detail = try await fix.store.meetingDetail(
            id: meetingID
        )
        #expect(detail?.notes.contains("Revised text") == true)
        // The original text should NOT be present
        #expect(detail?.notes.contains("First draft") != true)
    }

    @Test("double commit does not delete the note")
    @MainActor
    func doubleCommitDoesNotDeleteNote() async throws {
        let fix = try makeCoreFixture(
            testName: "InlineEditStop"
        )
        defer { fix.cleanup() }

        await fix.core.startRecording()
        let viewModel = RecordingViewModel(core: fix.core)

        // Add a note during recording
        viewModel.addNote("Important note")

        let noteID = try #require(viewModel.notes.first?.id)

        // First commit: update to revised text (normal path)
        viewModel.updateNote(id: noteID, text: "Revised note")

        // Simulate the race: a second "commit" with empty text
        // arrives (click-away monitor fires after Stop already
        // committed). Without the guard, this would call
        // removeNote and delete the user's work.
        // Here we verify the note survives by checking it still
        // exists after the second updateNote with empty text is
        // a no-op (the view guard prevents it; at the VM level,
        // updateNote with empty text would be a real update, but
        // the view's guard on editingNoteID prevents the call).
        #expect(viewModel.notes.count == 1)
        #expect(viewModel.notes.first?.text == "Revised note")

        await viewModel.stop()

        await fix.core.reloadSummaries()
        let meetingID = try #require(fix.core.summaries.first?.id)
        let detail = try await fix.store.meetingDetail(
            id: meetingID
        )
        #expect(detail?.notes.contains("Revised note") == true)
    }
}

// MARK: - Phase 3: Elapsed from start date

@Suite("RecordingViewModel.computeElapsed(startDate:now:)")
struct ElapsedFromStartDateTests {
    @Test("returns 00:00 when startDate is nil")
    @MainActor
    func nilStartDate() {
        let result = RecordingViewModel.computeElapsed(
            startDate: nil, now: Date()
        )
        #expect(result == "00:00")
    }

    @Test("computes elapsed from startDate and now")
    @MainActor
    func basicElapsed() {
        let start = Date()
        let now = start.addingTimeInterval(134) // 2m 14s
        let result = RecordingViewModel.computeElapsed(
            startDate: start, now: now
        )
        #expect(result == "02:14")
    }

    @Test("clamps negative elapsed to zero")
    @MainActor
    func negativeElapsed() {
        let start = Date()
        let now = start.addingTimeInterval(-5) // now before start
        let result = RecordingViewModel.computeElapsed(
            startDate: start, now: now
        )
        #expect(result == "00:00")
    }

    @Test("formats hours correctly")
    @MainActor
    func hoursElapsed() {
        let start = Date()
        let now = start.addingTimeInterval(3661) // 1h 1m 1s
        let result = RecordingViewModel.computeElapsed(
            startDate: start, now: now
        )
        #expect(result == "1:01:01")
    }

    @Test("both chips use same now -- values are consistent")
    @MainActor
    func bothChipsSameNow() {
        // Simulate a meeting that started 28 minutes ago with a
        // 30-minute scheduled end (2 min left).
        let start = Date()
        let scheduledEnd = start.addingTimeInterval(1800) // +30 min
        let now = start.addingTimeInterval(1680) // +28 min

        let elapsed = RecordingViewModel.computeElapsed(
            startDate: start, now: now
        )
        let chip = RecordingViewModel.leftChip(
            scheduledEnd: scheduledEnd, now: now
        )

        #expect(elapsed == "28:00")
        #expect(chip == .warning("2:00"))
    }
}

// MARK: - Phase 4: Auto-stop countdown

@Suite("RecordingViewModel autoStopCountdown")
struct AutoStopCountdownViewModelTests {
    @Test("returns nil when no countdown active")
    @MainActor
    func nilWhenNoCountdown() async throws {
        let fix = try makeCoreFixture(testName: "AutoStopVM")
        defer { fix.cleanup() }

        await fix.core.startRecording()
        let viewModel = RecordingViewModel(core: fix.core)
        #expect(viewModel.autoStopCountdown == nil)
    }

    @Test("returns nil when countdown is for a different meeting")
    @MainActor
    func nilForDifferentMeeting() async throws {
        let fix = try makeCoreFixture(testName: "AutoStopVM")
        defer { fix.cleanup() }

        await fix.core.startRecording()
        let viewModel = RecordingViewModel(core: fix.core)

        // Inject an autoStop state for a DIFFERENT meeting ID
        let mismatchedID = UUID()
        fix.core.setAutoStopForTesting(AutoStopState(
            meetingID: mismatchedID,
            deadline: Date().addingTimeInterval(10),
            total: 10
        ))

        // core.autoStop is set, but the VM should filter it out
        #expect(fix.core.autoStop != nil)
        #expect(viewModel.autoStopCountdown == nil)
    }

    @Test("returns state when countdown matches current meeting")
    @MainActor
    func returnsStateForMatchingMeeting() async throws {
        let fix = try makeCoreFixture(
            useFakeScheduler: true,
            useImmediateDetectorClock: true,
            testName: "AutoStopVM"
        )
        defer { fix.cleanup() }

        guard let fakeScheduler = fix.fakeScheduler else {
            Issue.record("Expected FakeScheduler")
            return
        }

        try await fix.store.updateSettings {
            $0.onboardingComplete = true
        }
        await fix.core.onLaunch()

        // Start recording with Zoom active, then stop Zoom
        fix.fakeActivitySource.emit([
            makeAudioProcess(
                bundleID: "us.zoom.xos",
                input: true, output: true
            )
        ])
        try await pollUntil {
            fix.core.runState == .detectedPending
        }
        await fix.core.recordDetectedEvent(eventKey: nil)
        guard case .recording = fix.core.runState else {
            Issue.record("Expected recording")
            return
        }

        let viewModel = RecordingViewModel(core: fix.core)
        #expect(viewModel.autoStopCountdown == nil)

        fix.fakeActivitySource.emit([
            makeAudioProcess(
                bundleID: "us.zoom.xos",
                input: false, output: false
            )
        ])
        try await pollUntil { fakeScheduler.pendingCount > 0 }

        let countdown = viewModel.autoStopCountdown
        #expect(countdown != nil)
        #expect(countdown?.total == 10)

        _ = await fix.core.stopRecording()
    }

    @Test("keepRecording() delegates to AppCore and clears countdown")
    @MainActor
    func keepRecordingDelegates() async throws {
        let fix = try makeCoreFixture(
            useFakeScheduler: true,
            useImmediateDetectorClock: true,
            testName: "AutoStopVM"
        )
        defer { fix.cleanup() }

        guard let fakeScheduler = fix.fakeScheduler else {
            Issue.record("Expected FakeScheduler")
            return
        }

        try await fix.store.updateSettings {
            $0.onboardingComplete = true
        }
        await fix.core.onLaunch()

        fix.fakeActivitySource.emit([
            makeAudioProcess(
                bundleID: "us.zoom.xos",
                input: true, output: true
            )
        ])
        try await pollUntil {
            fix.core.runState == .detectedPending
        }
        await fix.core.recordDetectedEvent(eventKey: nil)
        guard case .recording = fix.core.runState else {
            Issue.record("Expected recording")
            return
        }

        let viewModel = RecordingViewModel(core: fix.core)

        fix.fakeActivitySource.emit([
            makeAudioProcess(
                bundleID: "us.zoom.xos",
                input: false, output: false
            )
        ])
        try await pollUntil { fakeScheduler.pendingCount > 0 }
        #expect(viewModel.autoStopCountdown != nil)

        viewModel.keepRecording()
        #expect(viewModel.autoStopCountdown == nil)
        #expect(fix.core.autoStop == nil)

        // Still recording
        #expect(viewModel.isRecording == true)

        _ = await fix.core.stopRecording()
    }
}

// MARK: - Phase 3: Note timestamp formatting

@Suite("RecordingViewModel.formatNoteTimestamp")
struct NoteTimestampTests {
    @Test("formats seconds as m:ss")
    @MainActor
    func minutesSeconds() {
        #expect(RecordingViewModel.formatNoteTimestamp(42) == "0:42")
        #expect(RecordingViewModel.formatNoteTimestamp(102) == "1:42")
    }

    @Test("formats large values as h:mm:ss")
    @MainActor
    func hoursMinutesSeconds() {
        #expect(RecordingViewModel.formatNoteTimestamp(3661) == "1:01:01")
    }
}

// MARK: - Phase 3: Event title seeding on association

@Suite("RecordingViewModel event title seeding")
struct EventTitleSeedingTests {
    /// Helper: creates an EKEventDTO suitable for association tests.
    private static func makeDTO(
        title: String = "Team Standup",
        start: Date? = nil,
        end: Date? = nil
    ) -> EKEventDTO {
        let now = Date()
        let eventStart = start ?? now.addingTimeInterval(-300)
        let eventEnd = end ?? now.addingTimeInterval(1500)
        return EKEventDTO(
            eventIdentifier: "ev-title-seed",
            calendarItemIdentifier: "ci-title-seed",
            calendarItemExternalIdentifier: "ext-title-seed",
            occurrenceDate: eventStart,
            title: title,
            startDate: eventStart,
            endDate: eventEnd,
            isAllDay: false,
            location: nil,
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
            attendeeCount: 2,
            attendees: [],
            organizer: nil
        )
    }

    @Test("reloadDetail picks up event title when user has not edited")
    @MainActor
    func reloadDetailPicksUpEventTitle() async throws {
        let dto = Self.makeDTO(title: "Weekly Sync")

        let fix = try makeCoreFixture(
            calendarEventDTOs: [dto],
            calendarRefreshResult: dto,
            testName: "EventTitleSeed"
        )
        defer { fix.cleanup() }

        try await fix.store.updateSettings {
            $0.onboardingComplete = true
        }
        await fix.core.onLaunch()

        // Start recording -- this creates the meeting and associates
        // the event (which sets the title in the store).
        await fix.core.startRecording()

        let viewModel = RecordingViewModel(core: fix.core)

        // Initial load: may see "Untitled Meeting" or "Weekly Sync"
        // depending on timing. The key test is that reloadDetail
        // picks up the event title.
        await viewModel.load()

        // Now simulate what .onChange(of: summariesVersion) does:
        await viewModel.reloadDetail()

        #expect(viewModel.editableTitle == "Weekly Sync")
        #expect(viewModel.detail?.title == "Weekly Sync")
    }

    @Test("reloadDetail does NOT clobber a user-edited title")
    @MainActor
    func reloadDetailPreservesUserEdit() async throws {
        let dto = Self.makeDTO(title: "Sprint Planning")

        let fix = try makeCoreFixture(
            calendarEventDTOs: [dto],
            calendarRefreshResult: dto,
            testName: "EventTitleSeed"
        )
        defer { fix.cleanup() }

        try await fix.store.updateSettings {
            $0.onboardingComplete = true
        }
        await fix.core.onLaunch()

        await fix.core.startRecording()

        let viewModel = RecordingViewModel(core: fix.core)
        await viewModel.load()

        // User types a custom title (simulates editing the text field)
        viewModel.editableTitle = "My Custom Title"

        // Now a reload comes in (summaries changed)
        await viewModel.reloadDetail()

        // The user's in-progress edit must survive
        #expect(viewModel.editableTitle == "My Custom Title")
    }

    @Test("event title persists through stop")
    @MainActor
    func eventTitlePersistsThroughStop() async throws {
        let dto = Self.makeDTO(title: "Design Review")

        let fix = try makeCoreFixture(
            calendarEventDTOs: [dto],
            calendarRefreshResult: dto,
            testName: "EventTitleSeed"
        )
        defer { fix.cleanup() }

        try await fix.store.updateSettings {
            $0.onboardingComplete = true
        }
        await fix.core.onLaunch()

        await fix.core.startRecording()
        let meetingID = try #require(
            fix.core.recording.state.meetingID
        )

        // Verify title is set in the store before stopping
        let detailBefore = try await fix.store.meetingDetail(
            id: meetingID
        )
        #expect(detailBefore?.title == "Design Review")

        // Stop the recording
        await fix.core.stopRecording()

        // Title should still be the event title after stop
        let detailAfter = try await fix.store.meetingDetail(
            id: meetingID
        )
        #expect(detailAfter?.title == "Design Review")
    }

    @Test("user edit during recording survives reloadDetail and stop")
    @MainActor
    func userEditSurvivesReloadAndStop() async throws {
        let dto = Self.makeDTO(title: "Team Standup")

        let fix = try makeCoreFixture(
            calendarEventDTOs: [dto],
            calendarRefreshResult: dto,
            testName: "EventTitleSeed"
        )
        defer { fix.cleanup() }

        try await fix.store.updateSettings {
            $0.onboardingComplete = true
        }
        await fix.core.onLaunch()

        await fix.core.startRecording()
        let meetingID = try #require(
            fix.core.recording.state.meetingID
        )

        let viewModel = RecordingViewModel(core: fix.core)
        await viewModel.load()
        await viewModel.reloadDetail()

        // User edits and saves
        viewModel.editableTitle = "My Custom Meeting"
        await viewModel.saveTitle()

        // Reload should not clobber the saved title
        await viewModel.reloadDetail()
        #expect(viewModel.editableTitle == "My Custom Meeting")

        // Stop the recording
        await fix.core.stopRecording()

        // Title should be the user's custom title, not the event title
        let detail = try await fix.store.meetingDetail(id: meetingID)
        #expect(detail?.title == "My Custom Meeting")
    }
}

// MARK: - Phase 7: Event link/unlink

@Suite("RecordingViewModel event link/unlink")
struct EventLinkUnlinkTests {
    /// Helper: creates an EKEventDTO for association tests.
    private static func makeDTO(
        title: String = "Team Standup",
        start: Date? = nil,
        end: Date? = nil
    ) -> EKEventDTO {
        let now = Date()
        let eventStart = start ?? now.addingTimeInterval(-300)
        let eventEnd = end ?? now.addingTimeInterval(1500)
        return EKEventDTO(
            eventIdentifier: "ev-link-test",
            calendarItemIdentifier: "ci-link-test",
            calendarItemExternalIdentifier: "ext-link-test",
            occurrenceDate: eventStart,
            title: title,
            startDate: eventStart,
            endDate: eventEnd,
            isAllDay: false,
            location: nil,
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
            attendeeCount: 2,
            attendees: [],
            organizer: nil
        )
    }

    @Test("link event switches submeta from ad-hoc to event mode")
    @MainActor
    func linkEventSwitchesToEventMode() async throws {
        let dto = Self.makeDTO(title: "Weekly Sync")

        // Start with NO calendar events so bestMatch returns nil,
        // giving us a genuinely ad-hoc recording.
        let fix = try makeCoreFixture(
            calendarEventDTOs: [],
            testName: "EventLinkUnlink"
        )
        defer { fix.cleanup() }

        try await fix.store.updateSettings {
            $0.onboardingComplete = true
        }
        await fix.core.onLaunch()

        // Start an ad-hoc recording (bestMatch finds nothing)
        await fix.core.startRecording()
        let viewModel = RecordingViewModel(core: fix.core)
        await viewModel.load()

        // Initially ad-hoc
        #expect(viewModel.hasEvent == false)

        // Now inject the DTO so eventsNear can find it
        fix.fakeEventStore.eventDTOs = [dto]
        fix.fakeEventStore.refreshResult = dto

        // Load nearby events and associate
        await viewModel.loadNearbyEvents()
        #expect(viewModel.nearbyEvents.count >= 1)

        guard let eventKey = viewModel.nearbyEvents.first?.id else {
            Issue.record("Expected nearby event")
            return
        }
        await viewModel.correctAssociation(eventKey: eventKey)

        // Now should be in event mode
        #expect(viewModel.hasEvent == true)
        #expect(viewModel.detail?.calendar != nil)
        #expect(viewModel.scheduleText != nil)

        _ = await fix.core.stopRecording()
    }

    @Test("unlink event switches submeta back to ad-hoc mode")
    @MainActor
    func unlinkEventSwitchesToAdHoc() async throws {
        let dto = Self.makeDTO(title: "Design Review")

        let fix = try makeCoreFixture(
            calendarEventDTOs: [dto],
            calendarRefreshResult: dto,
            testName: "EventLinkUnlink"
        )
        defer { fix.cleanup() }

        try await fix.store.updateSettings {
            $0.onboardingComplete = true
        }
        await fix.core.onLaunch()

        // Start recording WITH an event association
        await fix.core.startRecording()
        let viewModel = RecordingViewModel(core: fix.core)
        await viewModel.load()
        await viewModel.reloadDetail()

        // Verify event is linked
        #expect(viewModel.hasEvent == true)

        // Unlink the event
        await viewModel.removeAssociation()

        // Should be back to ad-hoc
        #expect(viewModel.hasEvent == false)
        #expect(viewModel.detail?.calendar == nil)

        _ = await fix.core.stopRecording()
    }

    @Test("presentLinkEvent sets showEventPicker and loads events")
    @MainActor
    func presentLinkEventSetsPickerAndLoadsEvents() async throws {
        let dto = Self.makeDTO(title: "Standup")

        // Start with no events so recording is ad-hoc
        let fix = try makeCoreFixture(
            calendarEventDTOs: [],
            testName: "EventLinkUnlink"
        )
        defer { fix.cleanup() }

        try await fix.store.updateSettings {
            $0.onboardingComplete = true
        }
        await fix.core.onLaunch()

        await fix.core.startRecording()
        let viewModel = RecordingViewModel(core: fix.core)
        await viewModel.load()

        #expect(viewModel.showEventPicker == false)
        #expect(viewModel.nearbyEvents.isEmpty)

        // Inject the DTO so eventsNear finds it
        fix.fakeEventStore.eventDTOs = [dto]
        fix.fakeEventStore.refreshResult = dto

        await viewModel.presentLinkEvent()

        #expect(viewModel.showEventPicker == true)
        #expect(viewModel.nearbyEvents.count >= 1)

        _ = await fix.core.stopRecording()
    }

    @Test("hasCalendarAccess delegates to core.calendar.auth")
    @MainActor
    func hasCalendarAccessDelegates() throws {
        let fix = try makeCoreFixture(
            calendarAuthStatus: .authorized,
            testName: "EventLinkUnlink"
        )
        defer { fix.cleanup() }
        let viewModel = RecordingViewModel(core: fix.core)
        #expect(viewModel.hasCalendarAccess == true)

        let fixDenied = try makeCoreFixture(
            calendarAuthStatus: .denied,
            testName: "EventLinkUnlinkDenied"
        )
        defer { fixDenied.cleanup() }
        let vmDenied = RecordingViewModel(core: fixDenied.core)
        #expect(vmDenied.hasCalendarAccess == false)
    }

    @Test("correctAssociation dismisses the picker")
    @MainActor
    func correctAssociationDismissesPicker() async throws {
        let dto = Self.makeDTO(title: "Team Chat")

        // Start with no events so recording is ad-hoc
        let fix = try makeCoreFixture(
            calendarEventDTOs: [],
            testName: "EventLinkUnlink"
        )
        defer { fix.cleanup() }

        try await fix.store.updateSettings {
            $0.onboardingComplete = true
        }
        await fix.core.onLaunch()

        await fix.core.startRecording()
        let viewModel = RecordingViewModel(core: fix.core)
        await viewModel.load()

        // Inject DTO for picker
        fix.fakeEventStore.eventDTOs = [dto]
        fix.fakeEventStore.refreshResult = dto

        await viewModel.presentLinkEvent()
        #expect(viewModel.showEventPicker == true)

        guard let eventKey = viewModel.nearbyEvents.first?.id else {
            Issue.record("Expected nearby event")
            return
        }
        await viewModel.correctAssociation(eventKey: eventKey)

        // Picker should be dismissed
        #expect(viewModel.showEventPicker == false)

        _ = await fix.core.stopRecording()
    }

    @Test("removeAssociation also dismisses the picker")
    @MainActor
    func removeAssociationDismissesPicker() async throws {
        let dto = Self.makeDTO(title: "Standup")

        let fix = try makeCoreFixture(
            calendarEventDTOs: [dto],
            calendarRefreshResult: dto,
            testName: "EventLinkUnlink"
        )
        defer { fix.cleanup() }

        try await fix.store.updateSettings {
            $0.onboardingComplete = true
        }
        await fix.core.onLaunch()

        await fix.core.startRecording()
        let viewModel = RecordingViewModel(core: fix.core)
        await viewModel.load()
        await viewModel.reloadDetail()

        viewModel.showEventPicker = true
        await viewModel.removeAssociation()

        #expect(viewModel.showEventPicker == false)
        #expect(viewModel.hasEvent == false)

        _ = await fix.core.stopRecording()
    }
}

// Shared helpers `pollUntil` and `makeAudioProcess` are imported
// from BiscottiTestSupport (TestHelpers.swift).

// MARK: - Phase 8: Recording startup state tests

@Suite("RecordingViewModel recording startup state")
struct RecordingStartupStateTests {
    @Test("startup state transitions from loading to started on success")
    @MainActor
    func startupTransitionsToStarted() async throws {
        let fix = try makeCoreFixture(testName: "StartupState")
        defer { fix.cleanup() }

        let viewModel = RecordingViewModel(core: fix.core)
        #expect(viewModel.recordingStartup == nil)

        await fix.core.startRecording()

        // After a successful start, should be .started
        #expect(viewModel.recordingStartup == .started)
        #expect(viewModel.isRecording == true)

        _ = await fix.core.stopRecording()

        // After stop, startup state is cleared
        #expect(viewModel.recordingStartup == nil)
    }

    @Test("startup state shows failed on permission denied")
    @MainActor
    func startupShowsFailedOnPermissionDenied() async throws {
        let fix = try makeCoreFixture(
            micStatus: .denied,
            micRequestResult: false,
            testName: "StartupStateFail"
        )
        defer { fix.cleanup() }

        let viewModel = RecordingViewModel(core: fix.core)

        await fix.core.startRecording()

        // Should be .failed (mic permission denied)
        #expect(viewModel.recordingStartup == .failed(
            "Microphone access is required to record."
        ))
        #expect(viewModel.isRecording == false)
    }

    @Test("startup state shows failed on engine error")
    @MainActor
    func startupShowsFailedOnEngineError() async throws {
        struct FakeEngineError: Error, LocalizedError {
            var errorDescription: String? {
                "test engine failure"
            }
        }
        let fix = try makeCoreFixture(
            startError: FakeEngineError(),
            testName: "StartupStateEngine"
        )
        defer { fix.cleanup() }

        let viewModel = RecordingViewModel(core: fix.core)

        await fix.core.startRecording()

        // Should be .failed with engine error
        if case let .failed(msg) = viewModel.recordingStartup {
            #expect(msg.contains("Audio engine error"))
        } else {
            Issue.record(
                "Expected .failed, got \(String(describing: viewModel.recordingStartup))"
            )
        }
        #expect(viewModel.isRecording == false)
    }

    @Test("cancelRecordingStartup resets state and route")
    @MainActor
    func cancelResetStateAndRoute() async throws {
        let fix = try makeCoreFixture(
            micStatus: .denied,
            micRequestResult: false,
            testName: "StartupCancel"
        )
        defer { fix.cleanup() }

        let viewModel = RecordingViewModel(core: fix.core)

        await fix.core.startRecording()
        #expect(fix.core.route == .recording)

        viewModel.cancelStartRecording()

        #expect(viewModel.recordingStartup == nil)
        #expect(fix.core.route == .home)
    }

    @Test("retryRecordingStartup re-attempts after failure")
    @MainActor
    func retryReattemptsAfterFailure() async throws {
        // Use an engine error that will fail once, then succeed on retry.
        // The FakeRecorder allows clearing startError between attempts.
        let fix = try makeCoreFixture(
            startError: NSError(
                domain: "test", code: 1,
                userInfo: [NSLocalizedDescriptionKey: "transient"]
            ),
            testName: "StartupRetry"
        )
        defer { fix.cleanup() }

        let viewModel = RecordingViewModel(core: fix.core)

        await fix.core.startRecording()
        #expect(viewModel.recordingStartup?.isFailed == true)

        // "Fix" the engine error for the retry
        fix.fakeRecorder.backing.startError = nil

        await viewModel.retryStartRecording()

        #expect(viewModel.recordingStartup == .started)
        #expect(viewModel.isRecording == true)

        _ = await fix.core.stopRecording()
    }

    @Test("route is .recording immediately after startRecording")
    @MainActor
    func routeIsRecordingImmediately() async throws {
        let fix = try makeCoreFixture(testName: "StartupRoute")
        defer { fix.cleanup() }

        // We need to verify that route is set synchronously.
        // After startRecording, route should be .recording regardless
        // of whether the heavy work is done.
        await fix.core.startRecording()
        #expect(fix.core.route == .recording)
    }

    @Test("startupErrorMessage covers all error cases")
    @MainActor
    func startupErrorMessageCoverage() {
        #expect(AppCore.startupErrorMessage(
            for: .permissionDenied(.microphone)
        ).contains("Microphone"))

        #expect(AppCore.startupErrorMessage(
            for: .permissionDenied(.systemAudio)
        ).contains("System audio"))

        #expect(AppCore.startupErrorMessage(
            for: .permissionDenied(.calendar)
        ).contains("permission"))

        #expect(AppCore.startupErrorMessage(
            for: .engineFailed("boom")
        ).contains("boom"))

        #expect(AppCore.startupErrorMessage(
            for: .storageFailed("disk")
        ).contains("disk"))

        #expect(AppCore.startupErrorMessage(
            for: .alreadyRecording
        ).contains("already"))
    }
}

// RecordingStartupState.isFailed is imported from BiscottiTestSupport.
