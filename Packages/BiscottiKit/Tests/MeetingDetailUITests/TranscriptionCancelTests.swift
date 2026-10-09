import BiscottiTestSupport
import DataStore
import Foundation
import Testing
import TranscriptionService
@testable import AppCore
@testable import MeetingDetailUI

@Suite("MeetingDetailViewModel -- cancel transcription")
@MainActor
struct TranscriptionCancelTests {
    // MARK: - Cancel visibility

    @Test(
        "the Cancel button shows only while a job runs",
        arguments: [
            (JobStatus.downloadingModel(message: "x"), true),
            (JobStatus.transcribing, true),
            (JobStatus.idle, false),
            (JobStatus.completed, false),
            (JobStatus.cancelled, false),
            (JobStatus.failed(message: "boom", retriable: true), false)
        ]
    )
    func cancelVisibility(status: JobStatus, expected: Bool) async throws {
        let fix = try makeCoreFixture(testName: "TranscriptionCancel")
        defer { fix.cleanup() }
        let meetingID = try await fix.createMeetingWithAudio()
        fix.core.transcription.jobs[meetingID] = status

        let viewModel = MeetingDetailViewModel(core: fix.core, meetingID: meetingID)
        await viewModel.load()

        #expect(viewModel.isTranscriptionRunning == expected)
    }

    @Test("no job at all means no Cancel button")
    func noJobNoCancel() async throws {
        let fix = try makeCoreFixture(testName: "TranscriptionCancel")
        defer { fix.cleanup() }
        let meetingID = try await fix.createMeetingWithAudio()

        let viewModel = MeetingDetailViewModel(core: fix.core, meetingID: meetingID)
        await viewModel.load()

        #expect(!viewModel.isTranscriptionRunning)
    }

    // MARK: - Cancel action

    @Test("cancelTranscription stops the running job via the service")
    func cancelInvokesService() async throws {
        let fix = try makeCoreFixture(testName: "TranscriptionCancel")
        defer { fix.cleanup() }
        let meetingID = try await fix.createMeetingWithAudio()
        fix.fakeEngine.backing.blocksUntilShutdown = true

        let job = Task { @MainActor in
            await fix.core.transcription.transcribe(meetingID: meetingID)
        }
        for _ in 0 ..< 500 where !fix.fakeEngine.backing.processAudioStarted {
            try await Task.sleep(for: .milliseconds(10))
        }
        let viewModel = MeetingDetailViewModel(core: fix.core, meetingID: meetingID)
        await viewModel.load()
        #expect(viewModel.isTranscriptionRunning)

        await viewModel.cancelTranscription()
        await job.value

        #expect(fix.core.transcription.jobs[meetingID] == .cancelled)
        #expect(fix.fakeEngine.backing.shutdownCallCount == 1)
        #expect(!viewModel.isTranscriptionRunning)
        #expect(viewModel.displayState == .cancelled(canDelete: false))
    }

    @Test("cancelTranscription with no running job does nothing")
    func cancelWithoutJobIsNoOp() async throws {
        let fix = try makeCoreFixture(testName: "TranscriptionCancel")
        defer { fix.cleanup() }
        let meetingID = try await fix.createMeetingWithAudio()
        let viewModel = MeetingDetailViewModel(core: fix.core, meetingID: meetingID)
        await viewModel.load()

        await viewModel.cancelTranscription()

        #expect(fix.core.transcription.jobs[meetingID] == nil)
        #expect(fix.fakeEngine.backing.shutdownCallCount == 0)
    }

    // MARK: - Cancelled state

    @Test("cancelled imported meeting without a transcript offers Delete")
    func cancelledImportedCanDelete() async throws {
        let fix = try makeCoreFixture(testName: "TranscriptionCancel")
        defer { fix.cleanup() }
        let meetingID = try await makeImportedMeeting(fix)
        fix.core.transcription.jobs[meetingID] = .cancelled

        let viewModel = MeetingDetailViewModel(core: fix.core, meetingID: meetingID)
        await viewModel.load()

        #expect(viewModel.isImportedAudio)
        #expect(viewModel.displayState == .cancelled(canDelete: true))
        #expect(viewModel.canReTranscribe)
    }

    @Test("a recorded (mic + system) meeting is not treated as imported")
    func recordedIsNotImported() async throws {
        let fix = try makeCoreFixture(testName: "TranscriptionCancel")
        defer { fix.cleanup() }
        let meetingID = try await fix.createMeetingWithAudio()

        let viewModel = MeetingDetailViewModel(core: fix.core, meetingID: meetingID)
        await viewModel.load()

        #expect(!viewModel.isImportedAudio)
    }

    @Test("a single-track recording named mic.aac is not treated as imported")
    func singleTrackRecordingIsNotImported() async throws {
        let fix = try makeCoreFixture(testName: "TranscriptionCancel")
        defer { fix.cleanup() }
        let meetingID = try await fix.store.createMeeting(title: "Mic only")
        try await fix.store.attachAudio(
            [AudioFileRef(role: .mic, path: "/tmp/test/mic.aac", byteSize: 1, isPresent: true)],
            to: meetingID
        )

        let viewModel = MeetingDetailViewModel(core: fix.core, meetingID: meetingID)
        await viewModel.load()

        #expect(!viewModel.isImportedAudio)
    }

    @Test("a cancelled re-transcribe keeps the old transcript, even for imported audio")
    func cancelledWithTranscriptKeepsTranscript() async throws {
        let fix = try makeCoreFixture(testName: "TranscriptionCancel")
        defer { fix.cleanup() }
        let meetingID = try await makeImportedMeeting(fix)
        let transcriptID = try await fix.store.addTranscript(
            FakeTranscriber.defaultResult,
            vocabularyUsed: [],
            mappedEventIdentifier: nil,
            to: meetingID
        )
        try await fix.store.setPreferredTranscript(transcriptID, for: meetingID)
        fix.core.transcription.jobs[meetingID] = .cancelled

        let viewModel = MeetingDetailViewModel(core: fix.core, meetingID: meetingID)
        await viewModel.load()

        guard case .transcript = viewModel.displayState else {
            Issue.record("Expected .transcript, got \(viewModel.displayState)")
            return
        }
    }

    @Test("Delete from the cancelled state removes an imported meeting after confirmation")
    func deleteImportedAfterCancel() async throws {
        let fix = try makeCoreFixture(testName: "TranscriptionCancel")
        defer { fix.cleanup() }
        let meetingID = try await makeImportedMeeting(fix)
        fix.core.transcription.jobs[meetingID] = .cancelled
        await fix.core.reloadSummaries()
        fix.core.select(meetingID)

        let viewModel = MeetingDetailViewModel(core: fix.core, meetingID: meetingID)
        await viewModel.load()
        viewModel.requestDelete()
        #expect(viewModel.showDeleteConfirmation)
        // Nothing is deleted until the user confirms.
        #expect(try await fix.store.meetingExists(id: meetingID))

        await viewModel.confirmDelete()

        #expect(try await fix.store.meetingExists(id: meetingID) == false)
        #expect(fix.core.summaries.isEmpty)
        #expect(fix.core.route == .meetings)
    }

    // MARK: - Elapsed time

    @Test("elapsed time formats as m:ss and h:mm:ss, clamping negatives")
    func elapsedFormatting() {
        #expect(MeetingDetailViewModel.formatElapsed(0) == "0:00")
        #expect(MeetingDetailViewModel.formatElapsed(7.9) == "0:07")
        #expect(MeetingDetailViewModel.formatElapsed(65) == "1:05")
        #expect(MeetingDetailViewModel.formatElapsed(600) == "10:00")
        #expect(MeetingDetailViewModel.formatElapsed(3600) == "1:00:00")
        #expect(MeetingDetailViewModel.formatElapsed(3725) == "1:02:05")
        #expect(MeetingDetailViewModel.formatElapsed(-5) == "0:00")
    }

    @Test("elapsed text comes from the job start date and the supplied clock")
    func elapsedFromStartDate() async throws {
        let fix = try makeCoreFixture(testName: "TranscriptionCancel")
        defer { fix.cleanup() }
        let meetingID = try await fix.createMeetingWithAudio()
        let start = Date(timeIntervalSince1970: 1_000_000)
        fix.core.transcription.jobs[meetingID] = .transcribing
        fix.core.transcription.jobStartedAt[meetingID] = start

        let viewModel = MeetingDetailViewModel(core: fix.core, meetingID: meetingID)

        #expect(viewModel.transcriptionElapsedText(now: start.addingTimeInterval(83)) == "1:23")
        #expect(viewModel.transcriptionElapsedText(now: start) == "0:00")
    }

    @Test("no elapsed text when idle or when the start date is unknown")
    func elapsedAbsent() async throws {
        let fix = try makeCoreFixture(testName: "TranscriptionCancel")
        defer { fix.cleanup() }
        let meetingID = try await fix.createMeetingWithAudio()
        let viewModel = MeetingDetailViewModel(core: fix.core, meetingID: meetingID)
        let now = Date(timeIntervalSince1970: 2_000_000)

        // Not running.
        #expect(viewModel.transcriptionElapsedText(now: now) == nil)

        // Running but no start date recorded.
        fix.core.transcription.jobs[meetingID] = .transcribing
        #expect(viewModel.transcriptionElapsedText(now: now) == nil)

        // Finished: start date is ignored once the job is no longer running.
        fix.core.transcription.jobStartedAt[meetingID] = now
        fix.core.transcription.jobs[meetingID] = .completed
        #expect(viewModel.transcriptionElapsedText(now: now) == nil)
    }

    @Test("the service records the start date while running and clears it after")
    func serviceTracksStartDate() async throws {
        let fix = try makeCoreFixture(testName: "TranscriptionCancel")
        defer { fix.cleanup() }
        let meetingID = try await fix.createMeetingWithAudio()
        fix.fakeEngine.backing.blocksUntilShutdown = true

        let job = Task { @MainActor in
            await fix.core.transcription.transcribe(meetingID: meetingID)
        }
        for _ in 0 ..< 500 where !fix.fakeEngine.backing.processAudioStarted {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(fix.core.transcription.jobStartedAt[meetingID] != nil)

        await fix.core.transcription.cancel(meetingID: meetingID)
        await job.value
        #expect(fix.core.transcription.jobStartedAt[meetingID] == nil)
    }

    // MARK: - Helpers

    /// A meeting shaped like `AppCore.importAudioFile` output: one `.mic` ref
    /// named `imported.<ext>` and no system track.
    private func makeImportedMeeting(_ fix: CoreFixture) async throws -> UUID {
        let meetingID = try await fix.store.createMeeting(title: "Imported")
        try await fix.store.attachAudio(
            [AudioFileRef(
                role: .mic, path: "/tmp/test/\(meetingID)/imported.wav",
                byteSize: 1, isPresent: true
            )],
            to: meetingID
        )
        return meetingID
    }
}
