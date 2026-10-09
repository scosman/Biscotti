import BiscottiTestSupport
import Foundation
import Testing
import Transcription
import TranscriptionService
@testable import AppCore
@testable import DataStore

@Suite("AppCore -- transcription queue")
@MainActor
struct TranscriptionQueueTests {
    /// Starts `meetingID`'s transcription and waits until the (blocked)
    /// engine is inside it, so the queue holds a turn.
    private static func startBlockedJob(_ fix: CoreFixture, meetingID: UUID) async throws {
        fix.fakeEngine.backing.blocksUntilShutdown = true
        fix.core.spawnTranscription(meetingID: meetingID)
        for _ in 0 ..< 500 where !fix.fakeEngine.backing.processAudioStarted {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(fix.fakeEngine.backing.processAudioStarted)
    }

    @Test("an import started while a transcription runs waits, then transcribes")
    func importWaitsForRunningJob() async throws {
        let fix = try makeCoreFixture(testName: "QueueImportWaits")
        defer { fix.cleanup() }
        let dir = try AppCoreAudioImportTests.makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let source = try AppCoreAudioImportTests.writeWAV(named: "later.wav", in: dir)
        let running = try await fix.createMeetingWithAudio(title: "running")
        try await Self.startBlockedJob(fix, meetingID: running)

        let imported = try await AppCoreAudioImportTests.unwrap(fix.core.importAudioFile(at: source))

        #expect(fix.core.transcription.jobs[running] == .transcribing)
        #expect(fix.core.transcription.jobs[imported] == .queued)

        fix.fakeEngine.backing.blocksUntilShutdown = false
        await fix.core.awaitPendingTranscription()

        #expect(fix.core.transcription.jobs[running] == .completed)
        #expect(fix.core.transcription.jobs[imported] == .completed)
        #expect(try await fix.store.meetingDetail(id: imported)?.preferredTranscript != nil)
    }

    @Test("several meetings spawned while one runs all complete, none overwritten")
    func manySpawnedAllComplete() async throws {
        let fix = try makeCoreFixture(testName: "QueueMany")
        defer { fix.cleanup() }
        let first = try await fix.createMeetingWithAudio(title: "a")
        let second = try await fix.createMeetingWithAudio(title: "b")
        let third = try await fix.createMeetingWithAudio(title: "c")
        try await Self.startBlockedJob(fix, meetingID: first)

        fix.core.spawnTranscription(meetingID: second)
        fix.core.spawnTranscription(meetingID: third)
        #expect(fix.core.transcription.jobs[second] == .queued)
        #expect(fix.core.transcription.jobs[third] == .queued)

        fix.fakeEngine.backing.blocksUntilShutdown = false
        await fix.core.awaitPendingTranscription()

        for id in [first, second, third] {
            #expect(fix.core.transcription.jobs[id] == .completed)
        }
        #expect(fix.core.pendingTranscriptionTasks.isEmpty)
        #expect(fix.core.transcriptionQueue.queuedMeetingIDs.isEmpty)
        #expect(!fix.core.transcriptionQueue.hasActiveTurn)
    }

    @Test("cancelling a queued meeting dequeues it; the meeting stays and can be retried")
    func cancelQueuedDequeues() async throws {
        let fix = try makeCoreFixture(testName: "QueueCancel")
        defer { fix.cleanup() }
        let running = try await fix.createMeetingWithAudio(title: "running")
        let waiting = try await fix.createMeetingWithAudio(title: "waiting")
        try await Self.startBlockedJob(fix, meetingID: running)
        fix.core.spawnTranscription(meetingID: waiting)
        for _ in 0 ..< 200 where !fix.core.transcriptionQueue.isQueued(waiting) {
            try await Task.sleep(for: .milliseconds(5))
        }
        #expect(fix.core.transcriptionQueue.isQueued(waiting))

        await fix.core.cancelTranscription(meetingID: waiting)

        #expect(fix.core.transcription.jobs[waiting] == .cancelled)
        #expect(!fix.core.transcriptionQueue.isQueued(waiting))
        // The running job is untouched.
        #expect(fix.core.transcription.jobs[running] == .transcribing)

        fix.fakeEngine.backing.blocksUntilShutdown = false
        await fix.core.awaitPendingTranscription()
        #expect(fix.core.transcription.jobs[running] == .completed)
        #expect(fix.core.transcription.jobs[waiting] == .cancelled)
        #expect(try await fix.store.meetingExists(id: waiting))
        #expect(try await fix.store.meetingDetail(id: waiting)?.preferredTranscript == nil)

        // Retry works once the queue is free.
        let ran = await fix.core.runQueuedTranscription(meetingID: waiting) {
            await fix.core.transcription.transcribe(meetingID: waiting)
        }
        #expect(ran)
        #expect(fix.core.transcription.jobs[waiting] == .completed)
    }

    @Test("deleting a queued meeting dequeues it: never transcribed, the queue continues")
    func deleteQueuedMeeting() async throws {
        let fix = try makeCoreFixture(testName: "QueueDeleteQueued")
        defer { fix.cleanup() }
        let running = try await fix.createMeetingWithAudio(title: "running")
        let doomed = try await fix.createMeetingWithAudio(title: "doomed")
        let after = try await fix.createMeetingWithAudio(title: "after")
        try await Self.startBlockedJob(fix, meetingID: running)
        fix.core.spawnTranscription(meetingID: doomed)
        fix.core.spawnTranscription(meetingID: after)
        await fix.core.reloadSummaries()
        #expect(fix.core.transcriptionQueue.queuedMeetingIDs == [doomed, after])

        await fix.core.deleteMeeting(meetingID: doomed)

        #expect(fix.core.transcriptionQueue.queuedMeetingIDs == [after])
        #expect(fix.core.transcription.jobs[doomed] == nil)
        #expect(try await fix.store.meetingExists(id: doomed) == false)

        fix.fakeEngine.backing.blocksUntilShutdown = false
        await fix.core.awaitPendingTranscription()

        // Only "running" and "after" reached the engine.
        #expect(fix.fakeEngine.backing.ensureModelsCallCount == 2)
        #expect(fix.core.transcription.jobs[running] == .completed)
        #expect(fix.core.transcription.jobs[after] == .completed)
        #expect(fix.core.transcription.jobs[doomed] == nil)
        #expect(!fix.core.transcriptionQueue.hasActiveTurn)
    }

    @Test("deleting the running meeting cancels its job and the next queued one runs")
    func deleteRunningMeeting() async throws {
        let fix = try makeCoreFixture(testName: "QueueDeleteRunning")
        defer { fix.cleanup() }
        let running = try await fix.createMeetingWithAudio(title: "running")
        let next = try await fix.createMeetingWithAudio(title: "next")
        try await Self.startBlockedJob(fix, meetingID: running)
        fix.core.spawnTranscription(meetingID: next)
        await fix.core.reloadSummaries()
        #expect(fix.core.transcriptionQueue.queuedMeetingIDs == [next])

        // The next job must not block once it starts.
        fix.fakeEngine.backing.blocksUntilShutdown = false
        await fix.core.deleteMeeting(meetingID: running)
        await fix.core.awaitPendingTranscription()

        #expect(fix.fakeEngine.backing.shutdownCallCount >= 1)
        #expect(fix.core.transcription.jobs[running] == nil)
        #expect(try await fix.store.meetingExists(id: running) == false)
        #expect(fix.core.transcription.jobs[next] == .completed)
        #expect(try await fix.store.meetingDetail(id: next)?.preferredTranscript != nil)
        #expect(!fix.core.transcriptionQueue.hasActiveTurn)
        #expect(fix.core.transcription.jobStartedAt[running] == nil)
    }

    @Test("no auto-enhancements after a cancelled or failed spawned transcription")
    func noEnhancementsAfterCancelOrFailure() async throws {
        let fix = try makeCoreFixture(modelDownloaded: true, testName: "QueueNoEnhance")
        defer { fix.cleanup() }
        let meetingID = try await fix.createMeetingWithAudio()
        let transcriptID = try await fix.store.addTranscript(
            FakeTranscriber.defaultResult, vocabularyUsed: [],
            mappedEventIdentifier: nil, to: meetingID
        )
        try await fix.store.setPreferredTranscript(transcriptID, for: meetingID)

        // Cancelled.
        try await Self.startBlockedJob(fix, meetingID: meetingID)
        await fix.core.cancelTranscription(meetingID: meetingID)
        await fix.core.awaitPendingTranscription()
        #expect(fix.core.transcription.jobs[meetingID] == .cancelled)
        #expect(fix.fakeLLMRunner.sessionCount == 0)

        // Failed.
        fix.fakeEngine.backing.blocksUntilShutdown = false
        fix.fakeEngine.backing.processAudioError = TranscriptionError.transcriptionFailed("boom")
        fix.core.spawnTranscription(meetingID: meetingID)
        await fix.core.awaitPendingTranscription()
        guard case .failed = fix.core.transcription.jobs[meetingID] else {
            Issue.record("expected .failed, got \(String(describing: fix.core.transcription.jobs[meetingID]))")
            return
        }
        #expect(fix.fakeLLMRunner.sessionCount == 0)

        // Control: a successful run does reach the LLM.
        fix.fakeEngine.backing.processAudioError = nil
        fix.core.spawnTranscription(meetingID: meetingID)
        await fix.core.awaitPendingTranscription()
        #expect(fix.core.transcription.jobs[meetingID] == .completed)
        #expect(fix.fakeLLMRunner.sessionCount == 1)
    }

    @Test("a duplicate request for a queued meeting is ignored")
    func duplicateRequestIgnored() async throws {
        let fix = try makeCoreFixture(testName: "QueueDuplicate")
        defer { fix.cleanup() }
        let running = try await fix.createMeetingWithAudio(title: "running")
        let waiting = try await fix.createMeetingWithAudio(title: "waiting")
        try await Self.startBlockedJob(fix, meetingID: running)
        fix.core.spawnTranscription(meetingID: waiting)
        for _ in 0 ..< 200 where !fix.core.transcriptionQueue.isQueued(waiting) {
            try await Task.sleep(for: .milliseconds(5))
        }

        let ran = await fix.core.runQueuedTranscription(meetingID: waiting) {
            Issue.record("duplicate request must not run")
        }

        #expect(!ran)
        #expect(fix.core.transcriptionQueue.queuedMeetingIDs == [waiting])
        fix.fakeEngine.backing.blocksUntilShutdown = false
        await fix.core.awaitPendingTranscription()
    }
}
