import BiscottiTestSupport
import Foundation
import Testing
@testable import AppCore
@testable import MeetingDetailUI

@Suite("MeetingDetailViewModel -- queued transcription")
@MainActor
struct QueuedTranscriptionTests {
    @Test("a queued meeting shows the waiting state, offers Cancel, and blocks re-transcribe")
    func queuedState() async throws {
        let fix = try makeCoreFixture(testName: "QueuedState")
        defer { fix.cleanup() }
        let meetingID = try await fix.createMeetingWithAudio()
        fix.core.transcription.jobs[meetingID] = .queued
        let viewModel = MeetingDetailViewModel(core: fix.core, meetingID: meetingID)
        await viewModel.load()

        #expect(viewModel.displayState == .processing(
            message: "Queued \u{2014} waiting for the current transcription"
        ))
        #expect(viewModel.isTranscriptionQueued)
        #expect(!viewModel.isTranscriptionRunning)
        #expect(!viewModel.canReTranscribe)
    }

    @Test("Cancel on a queued meeting dequeues it and offers Retry")
    func cancelDequeues() async throws {
        let fix = try makeCoreFixture(testName: "QueuedCancel")
        defer { fix.cleanup() }
        let running = try await fix.createMeetingWithAudio(title: "running")
        let waiting = try await fix.createMeetingWithAudio(title: "waiting")
        fix.fakeEngine.backing.blocksUntilShutdown = true
        fix.core.spawnTranscription(meetingID: running)
        for _ in 0 ..< 500 where !fix.fakeEngine.backing.processAudioStarted {
            try await Task.sleep(for: .milliseconds(10))
        }
        fix.core.spawnTranscription(meetingID: waiting)
        for _ in 0 ..< 200 where !fix.core.transcriptionQueue.isQueued(waiting) {
            try await Task.sleep(for: .milliseconds(5))
        }
        let viewModel = MeetingDetailViewModel(core: fix.core, meetingID: waiting)
        await viewModel.load()

        await viewModel.cancelTranscription()

        #expect(viewModel.currentJobStatus == .cancelled)
        #expect(viewModel.displayState == .cancelled(canDelete: false))
        #expect(viewModel.canReTranscribe)
        fix.fakeEngine.backing.blocksUntilShutdown = false
        await fix.core.awaitPendingTranscription()
    }
}
