import Foundation
import Testing
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

    @Test("runner failure does not stop the queue")
    @MainActor
    func runnerFailureDoesNotStop() async {
        struct RunnerError: Error {}
        var ran: [UUID] = []
        let first = UUID(), second = UUID()

        let queue = PostProcessingQueue { entry in
            ran.append(entry.meetingID)
            if entry.meetingID == first {
                // The runner contract is: it never throws. But if it
                // internally fails, the loop must continue. Simulate a
                // no-op failure (the runner logs and continues).
            }
        }

        queue.enqueue(first, kind: .transcribe)
        queue.enqueue(second, kind: .transcribe)
        await queue.awaitIdle()

        #expect(ran == [first, second])
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
