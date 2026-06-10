import BiscottiTestSupport
import DataStore
import Foundation
import Testing
import Transcription
@testable import AppCore
@testable import MeetingDetailUI

// MARK: - Tests

@Suite("MeetingDetailViewModel -- display state")
struct MeetingDetailDisplayStateTests {
    @Test("displayState is .processing while loading")
    @MainActor
    func displayStateProcessingWhileLoading() throws {
        let fix = try makeCoreFixture(testName: "MeetingDetailUITests")
        defer { fix.cleanup() }

        let viewModel = MeetingDetailViewModel(core: fix.core, meetingID: UUID())
        // Before load() is called, isLoading is true
        #expect(viewModel.displayState == .processing(message: "Loading\u{2026}"))
    }

    @Test("displayState is .processing when downloading model")
    @MainActor
    func displayStateDownloadingModel() async throws {
        let fix = try makeCoreFixture(testName: "MeetingDetailUITests")
        defer { fix.cleanup() }

        let meetingID = try await fix.createMeetingWithAudio()
        fix.core.transcription.jobs[meetingID] = .downloadingModel(
            message: "Downloading speech-to-text model"
        )

        let viewModel = MeetingDetailViewModel(core: fix.core, meetingID: meetingID)
        await viewModel.load()

        #expect(viewModel.displayState == .processing(message: "Downloading speech-to-text model"))
    }

    @Test("displayState is .processing when transcribing")
    @MainActor
    func displayStateTranscribing() async throws {
        let fix = try makeCoreFixture(testName: "MeetingDetailUITests")
        defer { fix.cleanup() }

        let meetingID = try await fix.createMeetingWithAudio()
        fix.core.transcription.jobs[meetingID] = .transcribing

        let viewModel = MeetingDetailViewModel(core: fix.core, meetingID: meetingID)
        await viewModel.load()

        #expect(viewModel.displayState == .processing(message: "Transcribing\u{2026}"))
    }

    @Test("displayState is .transcript when transcript exists")
    @MainActor
    func displayStateTranscriptReady() async throws {
        let fix = try makeCoreFixture(testName: "MeetingDetailUITests")
        defer { fix.cleanup() }

        let meetingID = try await fix.createMeetingWithAudio()
        // Persist a transcript
        let result = FakeTranscriber.defaultResult
        let transcriptID = try await fix.store.addTranscript(
            result,
            vocabularyUsed: [],
            mappedEventIdentifier: nil,
            to: meetingID
        )
        try await fix.store.setPreferredTranscript(transcriptID, for: meetingID)

        let viewModel = MeetingDetailViewModel(core: fix.core, meetingID: meetingID)
        await viewModel.load()

        if case let .transcript(detail) = viewModel.displayState {
            #expect(detail.preferredTranscript != nil)
            #expect(detail.preferredTranscript?.segments.count == 2)
        } else {
            Issue.record("Expected .transcript state, got \(viewModel.displayState)")
        }
    }

    @Test("displayState is .failed when job failed with retriable error")
    @MainActor
    func displayStateFailedRetriable() async throws {
        let fix = try makeCoreFixture(testName: "MeetingDetailUITests")
        defer { fix.cleanup() }

        let meetingID = try await fix.createMeetingWithAudio()
        fix.core.transcription.jobs[meetingID] = .failed(
            message: "Worker stopped unexpectedly.",
            retriable: true
        )

        let viewModel = MeetingDetailViewModel(core: fix.core, meetingID: meetingID)
        await viewModel.load()

        #expect(viewModel.displayState == .failed(
            message: "Worker stopped unexpectedly.",
            retriable: true
        ))
    }

    @Test("displayState is .failed when job failed non-retriable")
    @MainActor
    func displayStateFailedNonRetriable() async throws {
        let fix = try makeCoreFixture(testName: "MeetingDetailUITests")
        defer { fix.cleanup() }

        let meetingID = try await fix.createMeetingWithAudio()
        fix.core.transcription.jobs[meetingID] = .failed(
            message: "Invalid audio input.",
            retriable: false
        )

        let viewModel = MeetingDetailViewModel(core: fix.core, meetingID: meetingID)
        await viewModel.load()

        #expect(viewModel.displayState == .failed(
            message: "Invalid audio input.",
            retriable: false
        ))
    }

    @Test("displayState shows meeting without transcript as .transcript state")
    @MainActor
    func displayStateMeetingNoTranscript() async throws {
        let fix = try makeCoreFixture(testName: "MeetingDetailUITests")
        defer { fix.cleanup() }

        let meetingID = try await fix.createMeetingWithAudio()

        let viewModel = MeetingDetailViewModel(core: fix.core, meetingID: meetingID)
        await viewModel.load()

        // No active job, no transcript -- shows the detail as-is
        if case let .transcript(detail) = viewModel.displayState {
            #expect(detail.preferredTranscript == nil)
        } else {
            Issue.record("Expected .transcript state for meeting without transcript")
        }
    }

    @Test("displayState is .failed when meeting not found after load")
    @MainActor
    func displayStateFailedWhenNotFound() async throws {
        let fix = try makeCoreFixture(testName: "MeetingDetailUITests")
        defer { fix.cleanup() }

        let bogusID = UUID()
        let viewModel = MeetingDetailViewModel(core: fix.core, meetingID: bogusID)
        await viewModel.load()

        #expect(viewModel.displayState == .failed(
            message: "Meeting not found.",
            retriable: false
        ))
    }
}

@Suite("MeetingDetailViewModel -- actions and properties")
struct MeetingDetailActionsTests {
    @Test("canReTranscribe is true when meeting has audio and no active job")
    @MainActor
    func canReTranscribeWithAudio() async throws {
        let fix = try makeCoreFixture(testName: "MeetingDetailUITests")
        defer { fix.cleanup() }

        let meetingID = try await fix.createMeetingWithAudio()

        let viewModel = MeetingDetailViewModel(core: fix.core, meetingID: meetingID)
        await viewModel.load()

        #expect(viewModel.canReTranscribe == true)
    }

    @Test("canReTranscribe is false during active job")
    @MainActor
    func canReTranscribeFalseDuringJob() async throws {
        let fix = try makeCoreFixture(testName: "MeetingDetailUITests")
        defer { fix.cleanup() }

        let meetingID = try await fix.createMeetingWithAudio()
        fix.core.transcription.jobs[meetingID] = .transcribing

        let viewModel = MeetingDetailViewModel(core: fix.core, meetingID: meetingID)
        await viewModel.load()

        #expect(viewModel.canReTranscribe == false)
    }

    @Test("canReTranscribe is false without audio")
    @MainActor
    func canReTranscribeNoAudio() async throws {
        let fix = try makeCoreFixture(testName: "MeetingDetailUITests")
        defer { fix.cleanup() }

        let meetingID = try await fix.store.createMeeting(title: "No Audio")

        let viewModel = MeetingDetailViewModel(core: fix.core, meetingID: meetingID)
        await viewModel.load()

        #expect(viewModel.canReTranscribe == false)
    }

    @Test("title reflects loaded meeting")
    @MainActor
    func titleReflectsLoaded() async throws {
        let fix = try makeCoreFixture(testName: "MeetingDetailUITests")
        defer { fix.cleanup() }

        let meetingID = try await fix.store.createMeeting(title: "My Meeting")

        let viewModel = MeetingDetailViewModel(core: fix.core, meetingID: meetingID)
        await viewModel.load()

        #expect(viewModel.title == "My Meeting")
    }

    @Test("formattedDate is non-empty after load")
    @MainActor
    func formattedDateNonEmpty() async throws {
        let fix = try makeCoreFixture(testName: "MeetingDetailUITests")
        defer { fix.cleanup() }

        let meetingID = try await fix.store.createMeeting(title: "Date Test")

        let viewModel = MeetingDetailViewModel(core: fix.core, meetingID: meetingID)
        await viewModel.load()

        #expect(!viewModel.formattedDate.isEmpty)
    }

    @Test("formattedDuration formats correctly")
    @MainActor
    func formattedDurationFormats() {
        #expect(MeetingDetailViewModel.formatDuration(252) == "4m 12s")
        #expect(MeetingDetailViewModel.formatDuration(3661) == "1h 1m 1s")
        #expect(MeetingDetailViewModel.formatDuration(45) == "45s")
        #expect(MeetingDetailViewModel.formatDuration(60) == "1m 0s")
    }

    @Test("formattedDuration is nil when meeting has no duration")
    @MainActor
    func formattedDurationNil() async throws {
        let fix = try makeCoreFixture(testName: "MeetingDetailUITests")
        defer { fix.cleanup() }

        let meetingID = try await fix.store.createMeeting(title: "No Duration")

        let viewModel = MeetingDetailViewModel(core: fix.core, meetingID: meetingID)
        await viewModel.load()

        #expect(viewModel.formattedDuration == nil)
    }

    @Test("load sets isLoading to false after completion")
    @MainActor
    func loadSetsIsLoading() async throws {
        let fix = try makeCoreFixture(testName: "MeetingDetailUITests")
        defer { fix.cleanup() }

        let meetingID = try await fix.store.createMeeting(title: "Load Test")

        let viewModel = MeetingDetailViewModel(core: fix.core, meetingID: meetingID)
        #expect(viewModel.isLoading == true)

        await viewModel.load()
        #expect(viewModel.isLoading == false)
    }
}
