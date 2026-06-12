import BiscottiTestSupport
import Calendar
import DataStore
import Foundation
import Testing
import Transcription
@testable import AppCore
@testable import MeetingDetailUI

// MARK: - Helpers

/// Polls a condition until true, up to `timeout` (default 2 s).
/// Checks every 50 ms so tests pass fast on idle machines but survive
/// parallel-load slowdowns that make a fixed `Task.sleep` flaky.
private func pollUntil(
    timeout: Duration = .seconds(2),
    _ condition: @MainActor () -> Bool
) async throws {
    let iterations = Int(timeout.components.seconds * 20
        + timeout.components.attoseconds / 50_000_000_000_000_000)
    for _ in 0 ..< max(iterations, 1) {
        if await condition() { return }
        try await Task.sleep(for: .milliseconds(50))
    }
}

// MARK: - FakeAudioPlayer

/// A fake audio player for testing playback state in the view model.
///
/// Not `@MainActor` to match the nonisolated `AudioPlaybackProviding`
/// protocol. Marked `@unchecked Sendable` — safe because all tests run
/// single-threaded on MainActor.
final class FakeAudioPlayer: AudioPlaybackProviding, @unchecked Sendable {
    var isPlaying: Bool = false
    var currentTime: TimeInterval = 0
    var duration: TimeInterval = 120 // 2 minutes
    var loadedURLs: [URL] = []
    var loadShouldThrow = false

    /// Track play/pause calls for sync verification.
    var playCalls: Int = 0
    var pauseCalls: Int = 0

    /// Simulates time advancing while playing. Tests call this to mimic
    /// real playback progression so the ticker picks up updated values.
    func advanceTime(by interval: TimeInterval) {
        guard isPlaying else { return }
        currentTime += interval
        // Stop at the end
        if currentTime >= duration {
            currentTime = duration
            isPlaying = false
        }
    }

    func play() {
        isPlaying = true
        playCalls += 1
    }

    func pause() {
        isPlaying = false
        pauseCalls += 1
    }

    func load(urls: [URL]) throws {
        if loadShouldThrow {
            throw NSError(
                domain: "FakeAudioPlayer",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: "Load failed"]
            )
        }
        loadedURLs = urls
    }
}

// MARK: - Audio playback tests

@Suite("MeetingDetailViewModel -- audio playback")
struct MeetingDetailAudioPlaybackTests {
    @Test("playback disabled when audio files missing")
    @MainActor
    func playbackDisabledWhenAudioMissing() async throws {
        let fix = try makeCoreFixture(testName: "Phase8Audio")
        defer { fix.cleanup() }

        // Create meeting without audio
        let meetingID = try await fix.store.createMeeting(
            title: "No Audio"
        )

        let viewModel = MeetingDetailViewModel(
            core: fix.core,
            meetingID: meetingID,
            makePlayer: { FakeAudioPlayer() }
        )
        await viewModel.load()

        #expect(viewModel.canPlay == false)
        #expect(viewModel.isAudioAvailable == false)
    }

    @Test("playback enabled when audio present")
    @MainActor
    func playbackEnabledWhenAudioPresent() async throws {
        let fix = try makeCoreFixture(testName: "Phase8Audio")
        defer { fix.cleanup() }

        let meetingID = try await fix.createMeetingWithAudio()

        // Create actual file so load succeeds
        let fakePlayer = FakeAudioPlayer()
        let viewModel = MeetingDetailViewModel(
            core: fix.core,
            meetingID: meetingID,
            makePlayer: { fakePlayer }
        )
        await viewModel.load()

        #expect(viewModel.isAudioAvailable == true)
        #expect(viewModel.canPlay == true)
        #expect(viewModel.audioPlayer != nil)
    }

    @Test("playPause toggles player state")
    @MainActor
    func playPauseToggles() async throws {
        let fix = try makeCoreFixture(testName: "Phase8Audio")
        defer { fix.cleanup() }

        let meetingID = try await fix.createMeetingWithAudio()

        let fakePlayer = FakeAudioPlayer()
        let viewModel = MeetingDetailViewModel(
            core: fix.core,
            meetingID: meetingID,
            makePlayer: { fakePlayer }
        )
        await viewModel.load()

        #expect(viewModel.isPlaying == false)

        viewModel.playPause()
        #expect(viewModel.isPlaying == true)

        viewModel.playPause()
        #expect(viewModel.isPlaying == false)
    }

    @Test("seek updates current time")
    @MainActor
    func seekUpdatesCurrentTime() async throws {
        let fix = try makeCoreFixture(testName: "Phase8Audio")
        defer { fix.cleanup() }

        let meetingID = try await fix.createMeetingWithAudio()

        let fakePlayer = FakeAudioPlayer()
        let viewModel = MeetingDetailViewModel(
            core: fix.core,
            meetingID: meetingID,
            makePlayer: { fakePlayer }
        )
        await viewModel.load()

        viewModel.seek(to: 30.0)
        #expect(fakePlayer.currentTime == 30.0)
    }

    @Test("playback duration reflects player")
    @MainActor
    func playbackDurationReflectsPlayer() async throws {
        let fix = try makeCoreFixture(testName: "Phase8Audio")
        defer { fix.cleanup() }

        let meetingID = try await fix.createMeetingWithAudio()

        let fakePlayer = FakeAudioPlayer()
        fakePlayer.duration = 300
        let viewModel = MeetingDetailViewModel(
            core: fix.core,
            meetingID: meetingID,
            makePlayer: { fakePlayer }
        )
        await viewModel.load()

        #expect(viewModel.playbackDuration == 300)
    }

    @Test("ticker advances stored currentTime while playing and stops on pause")
    @MainActor
    func tickerAdvancesCurrentTime() async throws {
        let fix = try makeCoreFixture(testName: "Phase8Ticker")
        defer { fix.cleanup() }

        let meetingID = try await fix.createMeetingWithAudio()

        let fakePlayer = FakeAudioPlayer()
        fakePlayer.duration = 120
        let viewModel = MeetingDetailViewModel(
            core: fix.core,
            meetingID: meetingID,
            makePlayer: { fakePlayer }
        )
        await viewModel.load()

        // Stored state starts at 0, not playing
        #expect(viewModel.isPlaying == false)
        #expect(viewModel.playbackCurrentTime == 0)

        // Start playback
        viewModel.playPause()
        #expect(viewModel.isPlaying == true)

        // Simulate player advancing 10s
        fakePlayer.advanceTime(by: 10)

        // Poll until the ticker syncs the player's time to the VM
        try await pollUntil { viewModel.playbackCurrentTime == 10 }

        // The stored currentTime should now reflect the player
        #expect(viewModel.playbackCurrentTime == 10)
        #expect(viewModel.isPlaying == true)

        // Pause stops the ticker
        viewModel.playPause()
        #expect(viewModel.isPlaying == false)

        // Simulate more time (should NOT be picked up)
        fakePlayer.currentTime = 20

        // Brief settle -- ticker is cancelled, so value must stay at 10.
        // Use pollUntil with an inverted condition: if it ever becomes 20
        // we have a bug. We poll a few cycles to give a cancelled ticker
        // a chance to fire erroneously, then assert the value is still 10.
        try await pollUntil(timeout: .milliseconds(300)) {
            viewModel.playbackCurrentTime == 20
        }

        // currentTime should remain at the paused value (synced on pause)
        #expect(viewModel.playbackCurrentTime == 10)
    }

    @Test("playback duration uses model recordingDuration over player guess")
    @MainActor
    func playbackDurationModelWins() async throws {
        let fix = try makeCoreFixture(testName: "Phase8ModelDur")
        defer { fix.cleanup() }

        // Create a meeting with a known recordingDuration (30 min = 1800s)
        let meetingID = try await fix.createMeetingWithAudio(
            recordingDuration: 1800
        )

        // Set the fake player's duration to a WRONG value (2h = 7200s),
        // simulating the bad ADTS-AAC size/bitrate guess.
        let fakePlayer = FakeAudioPlayer()
        fakePlayer.duration = 7200
        let viewModel = MeetingDetailViewModel(
            core: fix.core,
            meetingID: meetingID,
            makePlayer: { fakePlayer }
        )
        await viewModel.load()

        // After load, the displayed duration must be the model value,
        // NOT the player's wrong guess.
        #expect(viewModel.playbackDuration == 1800)

        // Start playback so the ticker fires at least once
        viewModel.playPause()
        fakePlayer.advanceTime(by: 5)

        // Poll until the ticker has run at least once
        try await pollUntil { viewModel.playbackCurrentTime == 5 }

        // The model value must STILL win -- syncPlaybackState must not
        // snap back to the player's 7200.
        #expect(viewModel.playbackDuration == 1800)

        viewModel.stopPlayback()
    }

    @Test("playback duration falls back to player when recordingDuration is nil")
    @MainActor
    func playbackDurationLegacyFallback() async throws {
        let fix = try makeCoreFixture(testName: "Phase8LegacyDur")
        defer { fix.cleanup() }

        // Create a meeting WITHOUT recordingDuration (legacy)
        let meetingID = try await fix.createMeetingWithAudio()

        let fakePlayer = FakeAudioPlayer()
        fakePlayer.duration = 1234
        let viewModel = MeetingDetailViewModel(
            core: fix.core,
            meetingID: meetingID,
            makePlayer: { fakePlayer }
        )
        await viewModel.load()

        // With no stored duration, the player's value is the fallback
        #expect(viewModel.playbackDuration == 1234)
    }

    @Test("stopPlayback cancels ticker and pauses player")
    @MainActor
    func stopPlaybackCancelsTicker() async throws {
        let fix = try makeCoreFixture(testName: "Phase8Ticker")
        defer { fix.cleanup() }

        let meetingID = try await fix.createMeetingWithAudio()

        let fakePlayer = FakeAudioPlayer()
        let viewModel = MeetingDetailViewModel(
            core: fix.core,
            meetingID: meetingID,
            makePlayer: { fakePlayer }
        )
        await viewModel.load()

        viewModel.playPause()
        #expect(viewModel.isPlaying == true)

        viewModel.stopPlayback()
        #expect(viewModel.isPlaying == false)
        #expect(fakePlayer.isPlaying == false)
    }
}

// MARK: - Transcript version tests

/// Creates a `TranscriptResult` with a unique ID for multi-version tests.
private func makeTranscriptResult() -> TranscriptResult {
    TranscriptResult(
        id: UUID(),
        createdAt: Date(timeIntervalSince1970: 1_700_000_000),
        transcriptionMethodId: "v1",
        language: "en",
        speakerCount: 1,
        segments: [
            TranscriptSegment(
                id: UUID(),
                speakerID: 0,
                speakerLabel: "Speaker 0",
                startTime: 0.0,
                endTime: 5.0,
                text: "Test segment.",
                confidence: 0.95,
                noSpeechProbability: 0.01,
                words: nil
            )
        ],
        speakerEmbeddings: [:],
        processingDuration: 1.0
    )
}

@Suite("MeetingDetailViewModel -- transcript versions")
struct MeetingDetailVersionTests {
    @Test("load populates versions when transcripts exist")
    @MainActor
    func detailLoadsVersions() async throws {
        let fix = try makeCoreFixture(testName: "Phase8Versions")
        defer { fix.cleanup() }

        let meetingID = try await fix.createMeetingWithAudio()
        let result = makeTranscriptResult()
        let tid = try await fix.store.addTranscript(
            result,
            vocabularyUsed: [],
            mappedEventIdentifier: nil,
            to: meetingID
        )
        try await fix.store.setPreferredTranscript(tid, for: meetingID)

        let viewModel = MeetingDetailViewModel(
            core: fix.core,
            meetingID: meetingID,
            makePlayer: { FakeAudioPlayer() }
        )
        await viewModel.load()

        #expect(viewModel.versions.count == 1)
        #expect(viewModel.versions.first?.id == tid)
        #expect(viewModel.versions.first?.isPreferred == true)
    }

    @Test("selectVersion loads the selected transcript")
    @MainActor
    func versionPickerLoadsSelectedVersion() async throws {
        let fix = try makeCoreFixture(testName: "Phase8Versions")
        defer { fix.cleanup() }

        let meetingID = try await fix.createMeetingWithAudio()

        // Add two transcripts with distinct IDs
        let result1 = makeTranscriptResult()
        let tid1 = try await fix.store.addTranscript(
            result1,
            vocabularyUsed: [],
            mappedEventIdentifier: nil,
            to: meetingID
        )
        try await fix.store.setPreferredTranscript(tid1, for: meetingID)

        let result2 = makeTranscriptResult()
        let tid2 = try await fix.store.addTranscript(
            result2,
            vocabularyUsed: [],
            mappedEventIdentifier: nil,
            to: meetingID
        )

        let viewModel = MeetingDetailViewModel(
            core: fix.core,
            meetingID: meetingID,
            makePlayer: { FakeAudioPlayer() }
        )
        await viewModel.load()

        #expect(viewModel.versions.count == 2)
        #expect(viewModel.selectedVersionID == nil)

        // Select the non-preferred version
        await viewModel.selectVersion(tid2)
        #expect(viewModel.selectedVersionID == tid2)
        #expect(viewModel.selectedTranscript != nil)
        #expect(viewModel.selectedTranscript?.id == tid2)
    }

    @Test("displayedTranscript reflects selection")
    @MainActor
    func displayedTranscriptReflectsSelection() async throws {
        let fix = try makeCoreFixture(testName: "Phase8Versions")
        defer { fix.cleanup() }

        let meetingID = try await fix.createMeetingWithAudio()

        let result1 = makeTranscriptResult()
        let tid1 = try await fix.store.addTranscript(
            result1,
            vocabularyUsed: [],
            mappedEventIdentifier: nil,
            to: meetingID
        )
        try await fix.store.setPreferredTranscript(tid1, for: meetingID)

        let result2 = makeTranscriptResult()
        let tid2 = try await fix.store.addTranscript(
            result2,
            vocabularyUsed: [],
            mappedEventIdentifier: nil,
            to: meetingID
        )

        let viewModel = MeetingDetailViewModel(
            core: fix.core,
            meetingID: meetingID,
            makePlayer: { FakeAudioPlayer() }
        )
        await viewModel.load()

        // Before selection: displayedTranscript is the preferred
        #expect(viewModel.displayedTranscript?.id == tid1)

        // After selection: displayedTranscript is the selected
        await viewModel.selectVersion(tid2)
        #expect(viewModel.displayedTranscript?.id == tid2)
    }

    @Test("selecting preferred version clears override")
    @MainActor
    func selectingPreferredClearsOverride() async throws {
        let fix = try makeCoreFixture(testName: "Phase8Versions")
        defer { fix.cleanup() }

        let meetingID = try await fix.createMeetingWithAudio()

        let result1 = makeTranscriptResult()
        let tid1 = try await fix.store.addTranscript(
            result1,
            vocabularyUsed: [],
            mappedEventIdentifier: nil,
            to: meetingID
        )
        try await fix.store.setPreferredTranscript(tid1, for: meetingID)

        let result2 = makeTranscriptResult()
        let tid2 = try await fix.store.addTranscript(
            result2,
            vocabularyUsed: [],
            mappedEventIdentifier: nil,
            to: meetingID
        )

        let viewModel = MeetingDetailViewModel(
            core: fix.core,
            meetingID: meetingID,
            makePlayer: { FakeAudioPlayer() }
        )
        await viewModel.load()

        // Select non-preferred, then switch back
        await viewModel.selectVersion(tid2)
        #expect(viewModel.selectedTranscript != nil)

        await viewModel.selectVersion(tid1)
        #expect(viewModel.selectedTranscript == nil)
        #expect(viewModel.displayedTranscript?.id == tid1)
    }

    @Test("activeVersionID returns preferred when none selected")
    @MainActor
    func activeVersionIDPreferred() async throws {
        let fix = try makeCoreFixture(testName: "Phase8Versions")
        defer { fix.cleanup() }

        let meetingID = try await fix.createMeetingWithAudio()
        let result = makeTranscriptResult()
        let tid = try await fix.store.addTranscript(
            result,
            vocabularyUsed: [],
            mappedEventIdentifier: nil,
            to: meetingID
        )
        try await fix.store.setPreferredTranscript(tid, for: meetingID)

        let viewModel = MeetingDetailViewModel(
            core: fix.core,
            meetingID: meetingID,
            makePlayer: { FakeAudioPlayer() }
        )
        await viewModel.load()

        #expect(viewModel.activeVersionID == tid)
    }
}

// MARK: - Notes autosave tests

@Suite("MeetingDetailViewModel -- notes autosave")
struct MeetingDetailNotesTests {
    @Test("notes loaded from detail")
    @MainActor
    func notesLoadedFromDetail() async throws {
        let fix = try makeCoreFixture(testName: "Phase8Notes")
        defer { fix.cleanup() }

        let meetingID = try await fix.store.createMeeting(
            title: "Notes Test"
        )
        try await fix.store.setNotes(
            "Existing notes content", for: meetingID
        )

        let viewModel = MeetingDetailViewModel(
            core: fix.core,
            meetingID: meetingID,
            makePlayer: { FakeAudioPlayer() }
        )
        await viewModel.load()

        #expect(viewModel.notes == "Existing notes content")
    }

    @Test("notes autosave debounces then persists")
    @MainActor
    func notesAutosaveDebounces() async throws {
        let fix = try makeCoreFixture(testName: "Phase8Notes")
        defer { fix.cleanup() }

        let meetingID = try await fix.store.createMeeting(
            title: "Debounce Test"
        )

        let viewModel = MeetingDetailViewModel(
            core: fix.core,
            meetingID: meetingID,
            makePlayer: { FakeAudioPlayer() }
        )
        await viewModel.load()

        // Update notes -- should not persist immediately
        viewModel.updateNotes("Updated notes")
        #expect(viewModel.notes == "Updated notes")

        // Verify not persisted yet
        let notesBeforeDebounce = try await fix.store.meetingDetail(
            id: meetingID
        )?.notes
        #expect(notesBeforeDebounce == "")

        // Poll until the debounce fires and persists the notes
        for _ in 0 ..< 40 { // 40 * 50ms = 2s timeout
            let notes = try await fix.store.meetingDetail(
                id: meetingID
            )?.notes
            if notes == "Updated notes" { break }
            try await Task.sleep(for: .milliseconds(50))
        }

        // Confirm persisted
        let notesAfterDebounce = try await fix.store.meetingDetail(
            id: meetingID
        )?.notes
        #expect(notesAfterDebounce == "Updated notes")
    }

    @Test("flushNotes persists immediately")
    @MainActor
    func flushNotesPersists() async throws {
        let fix = try makeCoreFixture(testName: "Phase8Notes")
        defer { fix.cleanup() }

        let meetingID = try await fix.store.createMeeting(
            title: "Flush Test"
        )

        let viewModel = MeetingDetailViewModel(
            core: fix.core,
            meetingID: meetingID,
            makePlayer: { FakeAudioPlayer() }
        )
        await viewModel.load()

        viewModel.updateNotes("Flush me")
        await viewModel.flushNotes()

        let persisted = try await fix.store.meetingDetail(
            id: meetingID
        )?.notes
        #expect(persisted == "Flush me")
    }
}

// MARK: - Association correction + re-transcribe tests

/// Creates a meeting-like `EKEventDTO` with the given identifier suffix.
private func makeMeetingEventDTO(suffix: String) -> EKEventDTO {
    let now = Date()
    return EKEventDTO(
        eventIdentifier: "ev-\(suffix)",
        calendarItemIdentifier: "ci-\(suffix)",
        calendarItemExternalIdentifier: "ext-\(suffix)",
        occurrenceDate: now,
        title: "Event \(suffix)",
        startDate: now,
        endDate: now.addingTimeInterval(3600),
        isAllDay: false,
        location: "https://zoom.us/j/\(suffix)",
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

@Suite("MeetingDetailViewModel -- association correction re-transcribe")
struct MeetingDetailCorrectionReTranscribeTests {
    // TODO(re-transcribe-prompt): restore this test once vocab support
    // (Phase 9) lands. The prompt is currently suppressed.
    @Test("association correction does NOT show re-transcribe prompt (vocab deferred)")
    @MainActor
    func associationCorrectionSuppressesPrompt() async throws {
        let dto = makeMeetingEventDTO(suffix: "retx")
        let fix = try makeCoreFixture(
            calendarEventDTOs: [dto],
            testName: "Phase8Correction"
        )
        defer { fix.cleanup() }

        try await fix.store.updateSettings {
            $0.onboardingComplete = true
        }
        await fix.core.onLaunch()

        let meetingID = try await fix.store.createMeeting(
            title: "Correction Test"
        )

        let viewModel = MeetingDetailViewModel(
            core: fix.core,
            meetingID: meetingID,
            makePlayer: { FakeAudioPlayer() }
        )
        await viewModel.load()

        guard let eventKey = fix.core.upcoming.first?.id else {
            Issue.record("Expected at least one upcoming event")
            return
        }

        await viewModel.correctAssociation(eventKey: eventKey)
        // Prompt suppressed until vocab support lands
        #expect(viewModel.showReTranscribeAfterCorrection == false)
    }

    @Test("reTranscribeAfterCorrection still works when invoked directly")
    @MainActor
    func reTranscribeAfterCorrectionTriggersJob() async throws {
        let dto = makeMeetingEventDTO(suffix: "retx2")
        let fix = try makeCoreFixture(
            calendarEventDTOs: [dto],
            testName: "Phase8Correction"
        )
        defer { fix.cleanup() }

        try await fix.store.updateSettings {
            $0.onboardingComplete = true
        }
        await fix.core.onLaunch()

        let meetingID = try await fix.createMeetingWithAudio()
        let viewModel = MeetingDetailViewModel(
            core: fix.core,
            meetingID: meetingID,
            makePlayer: { FakeAudioPlayer() }
        )
        await viewModel.load()

        // The prompt won't show after correction (suppressed), but
        // reTranscribeAfterCorrection() still functions if called
        await viewModel.reTranscribeAfterCorrection()
        #expect(viewModel.showReTranscribeAfterCorrection == false)

        // FakeTranscriber completes synchronously
        let job = fix.core.transcription.jobs[meetingID]
        #expect(job == .completed)
    }

    @Test("remove association clears context")
    @MainActor
    func removeAssociationClearsContext() async throws {
        let fix = try makeCoreFixture(testName: "Phase8Correction")
        defer { fix.cleanup() }

        let meetingID = try await fix.store.createMeeting(
            title: "Remove Test"
        )
        let snapshot = CalendarSnapshot(
            eventIdentifier: "ev-rm",
            calendarItemIdentifier: "ci-rm",
            calendarItemExternalIdentifier: "ext-rm",
            occurrenceStartDate: Date(),
            compositeKey: "key-rm",
            title: "Remove Me",
            startDate: Date(),
            endDate: Date().addingTimeInterval(3600),
            isAllDay: false,
            location: nil,
            url: nil,
            timeZone: nil,
            eventNotes: "",
            status: nil,
            availability: nil,
            calendarTitle: "Work",
            calendarColorHex: "#0066CC",
            conferenceURL: nil,
            conferencePlatform: nil
        )
        try await fix.store.setSnapshot(snapshot, for: meetingID)

        let viewModel = MeetingDetailViewModel(
            core: fix.core,
            meetingID: meetingID,
            makePlayer: { FakeAudioPlayer() }
        )
        await viewModel.load()
        #expect(viewModel.hasCalendarContext == true)

        await viewModel.removeAssociation()
        #expect(viewModel.hasCalendarContext == false)
        #expect(viewModel.calendarContext == nil)
        #expect(viewModel.showReTranscribeAfterCorrection == false)
    }
}
