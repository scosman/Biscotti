import Foundation
import TranscriptionService

// MARK: - FIFO turn gate

/// Serializes transcription jobs started by `AppCore` (recordings, imports,
/// re-transcribes, retries). `TranscriptionService` runs one job at a time
/// and fails a concurrent request, so each caller takes a turn here first;
/// the service's own guard stays as a safety net.
///
/// A turn covers whatever the caller does with it (for recordings and
/// imports: transcription plus auto-enhancements, so LLM work never overlaps
/// the next transcription).
@MainActor
final class TranscriptionQueue {
    private struct Waiter {
        let meetingID: UUID
        let continuation: CheckedContinuation<Bool, Never>
    }

    private var isBusy = false
    private var waiters: [Waiter] = []

    /// Whether a turn is currently held.
    var hasActiveTurn: Bool {
        isBusy
    }

    /// Meeting IDs waiting for a turn, in order.
    var queuedMeetingIDs: [UUID] {
        waiters.map(\.meetingID)
    }

    /// Whether `meetingID` is waiting for a turn.
    func isQueued(_ meetingID: UUID) -> Bool {
        waiters.contains { $0.meetingID == meetingID }
    }

    /// Takes a turn, suspending while another is held.
    ///
    /// - Parameter onWait: Called synchronously, before suspending, only
    ///   when the caller has to wait (used to publish the queued status).
    /// - Returns: `true` when the caller now holds the turn and must call
    ///   `release()`; `false` when the wait was cancelled via `dequeue`.
    func acquire(for meetingID: UUID, onWait: () -> Void) async -> Bool {
        if !isBusy {
            isBusy = true
            return true
        }
        onWait()
        return await withCheckedContinuation { continuation in
            waiters.append(Waiter(meetingID: meetingID, continuation: continuation))
        }
    }

    /// Ends the held turn, handing it to the next waiter if any.
    func release() {
        if waiters.isEmpty {
            isBusy = false
        } else {
            waiters.removeFirst().continuation.resume(returning: true)
        }
    }

    /// Removes every waiting entry for `meetingID`; their `acquire` calls
    /// return `false`. Returns whether anything was removed.
    @discardableResult
    func dequeue(_ meetingID: UUID) -> Bool {
        let removed = waiters.filter { $0.meetingID == meetingID }
        waiters.removeAll { $0.meetingID == meetingID }
        for waiter in removed {
            waiter.continuation.resume(returning: false)
        }
        return !removed.isEmpty
    }
}

// MARK: - AppCore API

package extension AppCore {
    /// Runs `body` (a transcription, usually followed by enhancements) when
    /// it is this meeting's turn. While another job is running or waiting,
    /// the meeting shows `.queued` instead of failing.
    ///
    /// Does nothing when the meeting is already queued or running.
    ///
    /// - Returns: `true` if `body` ran; `false` if skipped (duplicate request
    ///   or dequeued by `cancelTranscription`).
    @discardableResult
    func runQueuedTranscription(
        meetingID: UUID,
        _ body: @MainActor () async -> Void
    ) async -> Bool {
        if transcriptionQueue.isQueued(meetingID) { return false }
        switch transcription.jobs[meetingID] {
        case .transcribing, .downloadingModel:
            return false
        default:
            break
        }
        let granted = await transcriptionQueue.acquire(for: meetingID) {
            transcription.jobs[meetingID] = .queued
        }
        guard granted else { return false }
        await body()
        transcriptionQueue.release()
        return true
    }

    /// Fire-and-forget: queues transcription followed by auto-enhancements
    /// for a just-recorded or just-imported meeting. Tracked in
    /// `pendingTranscriptionTasks` so none is overwritten by a later one.
    func spawnTranscription(meetingID: UUID) {
        let key = UUID()
        // Show "Queued" right away rather than once the task first runs.
        if transcriptionQueue.hasActiveTurn {
            transcription.jobs[meetingID] = .queued
        }
        let task = Task { @MainActor [self] in
            await runQueuedTranscription(meetingID: meetingID) {
                await transcription.transcribe(meetingID: meetingID)
                await intelligence.runAutoEnhancements(meetingID: meetingID)
            }
            pendingTranscriptionTasks[key] = nil
        }
        pendingTranscriptionTasks[key] = task
        pendingTranscriptionTask = task
    }

    /// Cancels this meeting's transcription: dequeues it if it is waiting
    /// (status becomes `.cancelled`, so Retry is offered), otherwise cancels
    /// the running job.
    func cancelTranscription(meetingID: UUID) async {
        if transcriptionQueue.dequeue(meetingID) {
            transcription.jobs[meetingID] = .cancelled
        } else {
            await transcription.cancel(meetingID: meetingID)
        }
    }
}
