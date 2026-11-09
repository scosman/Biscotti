import BiscottiTestSupport
import Foundation
import Testing
import TranscriptionService
@testable import AppCore

@Suite("PostProcessingQueue")
struct PostProcessingQueueTests {
    @Test("enqueue runs entries in FIFO order")
    @MainActor
    func fifoOrder() async {
        var order: [UUID] = []
        let id1 = UUID(), id2 = UUID(), id3 = UUID()

        // Use a continuation to block the first entry until all are enqueued.
        let gate = Gate()

        let queue = PostProcessingQueue { entry in
            if entry.meetingID == id1 {
                await gate.wait()
            }
            order.append(entry.meetingID)
        }

        queue.enqueue(id1, kind: .transcribe)
        queue.enqueue(id2, kind: .transcribe)
        queue.enqueue(id3, kind: .transcribe)

        // Release the gate so all entries run
        gate.open()
        await queue.awaitIdle()

        #expect(order == [id1, id2, id3])
    }

    @Test("enqueue duplicate while waiting is a no-op")
    @MainActor
    func duplicateWhileWaiting() async {
        var runCount = 0
        let id = UUID()
        let gate = Gate()

        let queue = PostProcessingQueue { _ in
            await gate.wait()
            runCount += 1
        }

        // Enqueue a blocker first, then the id twice
        let blocker = UUID()
        queue.enqueue(blocker, kind: .transcribe)
        queue.enqueue(id, kind: .transcribe)
        queue.enqueue(id, kind: .reTranscribe) // duplicate -- ignored

        #expect(queue.waiting.count == 1) // only `id` is waiting (blocker is running)

        gate.open()
        await queue.awaitIdle()

        // blocker ran once, id ran once = 2 total
        #expect(runCount == 2)
    }

    @Test("enqueue duplicate while running is a no-op")
    @MainActor
    func duplicateWhileRunning() async {
        var runCount = 0
        let id = UUID()
        let gate = Gate()

        let queue = PostProcessingQueue { _ in
            await gate.wait()
            runCount += 1
        }

        queue.enqueue(id, kind: .transcribe)
        // id is now running
        #expect(queue.running?.meetingID == id)
        queue.enqueue(id, kind: .reTranscribe)
        #expect(queue.waiting.isEmpty)

        gate.open()
        await queue.awaitIdle()

        #expect(runCount == 1)
    }

    @Test("remove drops a waiting entry without affecting running")
    @MainActor
    func removeDropsWaiting() async {
        var ran: [UUID] = []
        let id1 = UUID(), id2 = UUID(), id3 = UUID()
        let gate = Gate()

        let queue = PostProcessingQueue { entry in
            if entry.meetingID == id1 { await gate.wait() }
            ran.append(entry.meetingID)
        }

        queue.enqueue(id1, kind: .transcribe)
        queue.enqueue(id2, kind: .transcribe)
        queue.enqueue(id3, kind: .transcribe)

        // id2 is waiting; remove it
        queue.remove(id2)
        #expect(!queue.isWaiting(id2))

        gate.open()
        await queue.awaitIdle()

        #expect(ran == [id1, id3])
    }

    @Test("isWaiting is true only before start")
    @MainActor
    func isWaitingTransitions() async {
        let id = UUID()
        let gate = Gate()

        let queue = PostProcessingQueue { _ in
            await gate.wait()
        }

        #expect(!queue.isWaiting(id))
        #expect(!queue.isActive(id))

        // Block with a dummy so id stays in waiting
        let blocker = UUID()
        queue.enqueue(blocker, kind: .transcribe)
        queue.enqueue(id, kind: .transcribe)

        #expect(queue.isWaiting(id))
        #expect(queue.isActive(id))
        #expect(!queue.isWaiting(blocker)) // blocker is running, not waiting
        #expect(queue.isActive(blocker))

        gate.open()
        await queue.awaitIdle()

        #expect(!queue.isWaiting(id))
        #expect(!queue.isActive(id))
    }

    @Test("service failure for one meeting does not stop the queue")
    @MainActor
    func serviceFailureDoesNotStopQueue() async throws {
        // Use the real AppCore pipeline with a FakeTranscriber that fails
        // on processAudio. The first meeting triggers the failure; the
        // second meeting should still be processed by the queue.
        let fix = try makeCoreFixture(testName: "PPQueueFailure")
        defer { fix.cleanup() }

        fix.fakeEngine.backing.processAudioError = NSError(
            domain: "test", code: 1
        )

        let id1 = try await fix.createMeetingWithAudio(title: "Failing")
        let id2 = try await fix.createMeetingWithAudio(title: "Succeeding")

        fix.core.postProcessing.enqueue(id1, kind: .transcribe)
        fix.core.postProcessing.enqueue(id2, kind: .transcribe)

        await fix.core.awaitPendingTranscription()

        // Both meetings must have been attempted (queue did not stall).
        // Both show .failed because the engine error persists, but the
        // second meeting proves the queue continued past the first.
        guard case .failed = fix.core.transcription.jobs[id1] else {
            Issue.record("expected .failed for first meeting")
            return
        }
        guard case .failed = fix.core.transcription.jobs[id2] else {
            Issue.record("expected .failed for second meeting (queue stalled)")
            return
        }
    }
}

// MARK: - Gate helper

/// A simple async gate for test synchronization.
@MainActor
private final class Gate {
    private var opened = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func open() {
        opened = true
        for waiter in waiters {
            waiter.resume()
        }
        waiters.removeAll()
    }

    func wait() async {
        if opened { return }
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            waiters.append(cont)
        }
    }
}
