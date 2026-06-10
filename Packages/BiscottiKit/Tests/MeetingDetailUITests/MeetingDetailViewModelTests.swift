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

    @Test("displayState shows Transcribing as headline with engine message as subtitle during model download")
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

        #expect(viewModel.displayState == .processing(
            message: "Transcribing\u{2026}",
            subtitle: "Downloading speech-to-text model"
        ))
    }

    @Test("displayState shows Transcribing as headline with no subtitle during active transcription")
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

// MARK: - Bug fix tests

@Suite("MeetingDetailViewModel -- status headline (Bug 1)")
struct MeetingDetailStatusHeadlineTests {
    @Test("processing state uses Transcribing as primary label, not the download message")
    @MainActor
    func transcribingHeadlineDuringDownload() async throws {
        let fix = try makeCoreFixture(testName: "MeetingDetailUITests")
        defer { fix.cleanup() }

        let meetingID = try await fix.createMeetingWithAudio()
        fix.core.transcription.jobs[meetingID] = .downloadingModel(
            message: "Downloading speech-to-text model"
        )

        let viewModel = MeetingDetailViewModel(core: fix.core, meetingID: meetingID)
        await viewModel.load()

        // The primary label must be "Transcribing..." not the engine's download message.
        if case let .processing(message, subtitle) = viewModel.displayState {
            #expect(message == "Transcribing\u{2026}")
            #expect(subtitle == "Downloading speech-to-text model")
        } else {
            Issue.record("Expected .processing state, got \(viewModel.displayState)")
        }
    }

    @Test("cached model run shows Transcribing with no download subtitle")
    @MainActor
    func cachedModelNoDownloadHeadline() async throws {
        let fix = try makeCoreFixture(testName: "MeetingDetailUITests")
        defer { fix.cleanup() }

        let meetingID = try await fix.createMeetingWithAudio()
        // When models are cached, the job goes straight to .transcribing
        // (skipping .downloadingModel entirely).
        fix.core.transcription.jobs[meetingID] = .transcribing

        let viewModel = MeetingDetailViewModel(core: fix.core, meetingID: meetingID)
        await viewModel.load()

        // No subtitle -- no download headline appears.
        #expect(viewModel.displayState == .processing(message: "Transcribing\u{2026}"))
        if case let .processing(_, subtitle) = viewModel.displayState {
            #expect(subtitle == nil)
        }
    }

    @Test("preparing status also shows Transcribing headline with engine message as subtitle")
    @MainActor
    func preparingStatusAsSubtitle() async throws {
        let fix = try makeCoreFixture(testName: "MeetingDetailUITests")
        defer { fix.cleanup() }

        let meetingID = try await fix.createMeetingWithAudio()
        fix.core.transcription.jobs[meetingID] = .downloadingModel(
            message: "Preparing\u{2026}"
        )

        let viewModel = MeetingDetailViewModel(core: fix.core, meetingID: meetingID)
        await viewModel.load()

        if case let .processing(message, subtitle) = viewModel.displayState {
            #expect(message == "Transcribing\u{2026}")
            #expect(subtitle == "Preparing\u{2026}")
        } else {
            Issue.record("Expected .processing state, got \(viewModel.displayState)")
        }
    }
}

@Suite("MeetingDetailViewModel -- auto-reload on completion (Bug 2)")
struct MeetingDetailAutoReloadTests {
    @Test("transcript appears after job completes without re-navigation")
    @MainActor
    func transcriptAppearsOnJobCompletion() async throws {
        let fix = try makeCoreFixture(testName: "MeetingDetailUITests")
        defer { fix.cleanup() }

        let meetingID = try await fix.createMeetingWithAudio()

        // Start with the job in-progress.
        fix.core.transcription.jobs[meetingID] = .transcribing

        let viewModel = MeetingDetailViewModel(core: fix.core, meetingID: meetingID)
        await viewModel.load()

        // Confirm we're in the processing state.
        #expect(viewModel.displayState == .processing(message: "Transcribing\u{2026}"))

        // Simulate transcription completing: persist a transcript and set the
        // job to .completed (mirroring what TranscriptionService.runJob does).
        let result = FakeTranscriber.defaultResult
        let transcriptID = try await fix.store.addTranscript(
            result,
            vocabularyUsed: [],
            mappedEventIdentifier: nil,
            to: meetingID
        )
        try await fix.store.setPreferredTranscript(transcriptID, for: meetingID)
        fix.core.transcription.jobs[meetingID] = .completed

        // Drive the same reload path the production view uses.
        await viewModel.onJobStatusChange(.completed)

        // The display state should now be .transcript with the data loaded.
        if case let .transcript(detail) = viewModel.displayState {
            #expect(detail.preferredTranscript != nil)
            #expect(detail.preferredTranscript?.segments.count == 2)
        } else {
            Issue.record("Expected .transcript state after completion, got \(viewModel.displayState)")
        }
    }

    @Test("sidebar summaries reload on job completion")
    @MainActor
    func sidebarReloadsOnCompletion() async throws {
        let fix = try makeCoreFixture(testName: "MeetingDetailUITests")
        defer { fix.cleanup() }

        let meetingID = try await fix.createMeetingWithAudio(title: "Sidebar Test")
        await fix.core.reloadSummaries()

        // Before transcription, hasTranscript is false.
        #expect(fix.core.summaries.first(where: { $0.id == meetingID })?.hasTranscript == false)

        // Persist a transcript and complete the job.
        let result = FakeTranscriber.defaultResult
        let transcriptID = try await fix.store.addTranscript(
            result,
            vocabularyUsed: [],
            mappedEventIdentifier: nil,
            to: meetingID
        )
        try await fix.store.setPreferredTranscript(transcriptID, for: meetingID)
        fix.core.transcription.jobs[meetingID] = .completed

        let viewModel = MeetingDetailViewModel(core: fix.core, meetingID: meetingID)
        await viewModel.onJobStatusChange(.completed)

        // Sidebar should now reflect hasTranscript = true.
        #expect(fix.core.summaries.first(where: { $0.id == meetingID })?.hasTranscript == true)
    }

    @Test("non-completed status changes do not reload detail")
    @MainActor
    func nonCompletedStatusDoesNotReload() async throws {
        let fix = try makeCoreFixture(testName: "MeetingDetailUITests")
        defer { fix.cleanup() }

        let meetingID = try await fix.createMeetingWithAudio()
        fix.core.transcription.jobs[meetingID] = .downloadingModel(message: "Preparing\u{2026}")

        let viewModel = MeetingDetailViewModel(core: fix.core, meetingID: meetingID)
        await viewModel.load()

        // Transition to .transcribing -- should not cause a reload that
        // clears the processing state.
        fix.core.transcription.jobs[meetingID] = .transcribing
        await viewModel.onJobStatusChange(.transcribing)

        #expect(viewModel.displayState == .processing(message: "Transcribing\u{2026}"))
    }
}
