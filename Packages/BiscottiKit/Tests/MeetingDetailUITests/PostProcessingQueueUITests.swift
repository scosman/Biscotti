import BiscottiTestSupport
import DataStore
import Foundation
import Testing
import Transcription
@testable import AppCore
@testable import MeetingDetailUI

// MARK: - Display state: queued

@Suite("MeetingDetailViewModel -- post-processing queue")
struct PostProcessingQueueUITests {
    @Test("displayState shows waiting-to-transcribe when queued")
    @MainActor
    func displayStateQueuedShowsWaiting() async throws {
        let fix = try makeCoreFixture(testName: "PPQueueUITests")
        defer { fix.cleanup() }

        let meetingID = try await fix.createMeetingWithAudio()
        let viewModel = MeetingDetailViewModel(
            core: fix.core, meetingID: meetingID
        )
        await viewModel.load()

        // Enqueue a blocker so our meeting stays queued
        let blocker = UUID()
        fix.core.postProcessing.enqueue(blocker, kind: .transcribe)
        fix.core.postProcessing.enqueue(meetingID, kind: .transcribe)

        #expect(
            viewModel.displayState
                == .processing(message: "Waiting to transcribe\u{2026}")
        )
    }

    @Test("displayState prefers waiting over stale failure")
    @MainActor
    func displayStateQueuedAfterFailure() async throws {
        let fix = try makeCoreFixture(testName: "PPQueueUITests")
        defer { fix.cleanup() }

        let meetingID = try await fix.createMeetingWithAudio()
        let viewModel = MeetingDetailViewModel(
            core: fix.core, meetingID: meetingID
        )
        await viewModel.load()

        // Set a stale failure
        fix.core.transcription.jobs[meetingID] = .failed(
            message: "Something went wrong", retriable: true
        )

        // Now enqueue a retry behind a blocker
        let blocker = UUID()
        fix.core.postProcessing.enqueue(blocker, kind: .transcribe)
        fix.core.postProcessing.enqueue(meetingID, kind: .transcribe)

        #expect(
            viewModel.displayState
                == .processing(message: "Waiting to transcribe\u{2026}")
        )
    }

    // MARK: - canReTranscribe

    @Test("canReTranscribe is false while queued")
    @MainActor
    func canReTranscribeFalseWhileQueued() async throws {
        let fix = try makeCoreFixture(testName: "PPQueueUITests")
        defer { fix.cleanup() }

        let meetingID = try await fix.createMeetingWithAudio()
        let viewModel = MeetingDetailViewModel(
            core: fix.core, meetingID: meetingID
        )
        await viewModel.load()

        // Normally canReTranscribe is true
        #expect(viewModel.canReTranscribe)

        // Enqueue -- now it's false
        fix.core.postProcessing.enqueue(meetingID, kind: .transcribe)
        #expect(!viewModel.canReTranscribe)
    }

    // MARK: - Pipeline stages

    @Test("pipelineStages shows 'Waiting to transcribe' when queued")
    @MainActor
    func pipelineStagesQueuedFirstStageWaiting() async throws {
        let fix = try makeCoreFixture(
            modelDownloaded: true,
            testName: "PPQueueUITests"
        )
        defer { fix.cleanup() }

        let meetingID = try await fix.createMeetingWithAudio()
        let viewModel = MeetingDetailViewModel(
            core: fix.core, meetingID: meetingID
        )
        await viewModel.load()

        // Enqueue behind a blocker so the meeting stays waiting
        let blocker = UUID()
        fix.core.postProcessing.enqueue(blocker, kind: .transcribe)
        fix.core.postProcessing.enqueue(meetingID, kind: .transcribe)

        let stages = try #require(viewModel.pipelineStages)
        #expect(stages.first?.label == "Waiting to transcribe")
        #expect(stages.first?.state == .pending)

        // All subsequent stages should be pending
        for stage in stages.dropFirst() {
            #expect(stage.state == .pending)
        }
    }

    // MARK: - retry / reTranscribe enqueue

    @Test("retry enqueues a .transcribe entry")
    @MainActor
    func retryEnqueuesTranscribeKind() async throws {
        let fix = try makeCoreFixture(testName: "PPQueueUITests")
        defer { fix.cleanup() }

        let meetingID = try await fix.createMeetingWithAudio()
        let viewModel = MeetingDetailViewModel(
            core: fix.core, meetingID: meetingID
        )
        await viewModel.load()

        viewModel.retry()

        // The meeting should be in the queue (running or waiting)
        #expect(fix.core.postProcessing.isActive(meetingID))
        #expect(fix.core.postProcessing.running?.kind == .transcribe)
    }

    @Test("reTranscribe enqueues a .reTranscribe entry")
    @MainActor
    func reTranscribeEnqueuesReTranscribeKind() async throws {
        let fix = try makeCoreFixture(testName: "PPQueueUITests")
        defer { fix.cleanup() }

        let meetingID = try await fix.createMeetingWithAudio()
        let viewModel = MeetingDetailViewModel(
            core: fix.core, meetingID: meetingID
        )
        await viewModel.load()

        viewModel.reTranscribe()

        #expect(fix.core.postProcessing.isActive(meetingID))
        #expect(fix.core.postProcessing.running?.kind == .reTranscribe)
    }

    // MARK: - Delete drops waiting entry

    @Test("deleting a queued meeting removes its waiting entry")
    @MainActor
    func deleteQueuedMeetingRemovesEntry() async throws {
        let fix = try makeCoreFixture(testName: "PPQueueUITests")
        defer { fix.cleanup() }

        let meetingID = try await fix.createMeetingWithAudio()

        // Enqueue behind a blocker so the meeting stays waiting
        let blocker = UUID()
        fix.core.postProcessing.enqueue(blocker, kind: .transcribe)
        fix.core.postProcessing.enqueue(meetingID, kind: .transcribe)

        #expect(fix.core.postProcessing.isWaiting(meetingID))

        await fix.core.deleteMeeting(meetingID: meetingID)

        #expect(!fix.core.postProcessing.isWaiting(meetingID))
        #expect(!fix.core.postProcessing.isActive(meetingID))
    }

    // MARK: - Two meetings both transcribe

    @Test("two meetings enqueued back-to-back both complete")
    @MainActor
    func twoMeetingsBothTranscribe() async throws {
        let fix = try makeCoreFixture(testName: "PPQueueUITests")
        defer { fix.cleanup() }

        let id1 = try await fix.createMeetingWithAudio(title: "Meeting 1")
        let id2 = try await fix.createMeetingWithAudio(title: "Meeting 2")

        fix.core.postProcessing.enqueue(id1, kind: .transcribe)
        fix.core.postProcessing.enqueue(id2, kind: .transcribe)

        await fix.core.awaitPendingTranscription()

        // Both must reach .completed (FakeTranscriber succeeds).
        #expect(fix.core.transcription.jobs[id1] == .completed)
        #expect(fix.core.transcription.jobs[id2] == .completed)
    }

    // MARK: - stopRecording enqueues transcribe

    @Test("stopRecording enqueues transcription via the queue")
    @MainActor
    func stopRecordingEnqueuesViaQueue() async throws {
        let fix = try makeCoreFixture(testName: "PPQueueUITests")
        defer { fix.cleanup() }

        await fix.core.startRecording()
        let meetingID = try #require(await fix.core.stopRecording())
        await fix.core.awaitPendingTranscription()

        // The transcription service should have been invoked
        let jobStatus = fix.core.transcription.jobs[meetingID]
        #expect(jobStatus != nil)
    }
}
