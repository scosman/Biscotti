import Foundation

/// App-wide serial FIFO of heavy post-recording work. Each entry runs the
/// injected runner to completion (transcribe -> AI auto-enhancements) before
/// the next starts. Main-actor; the runner's awaits hop to the services.
@MainActor @Observable
public final class PostProcessingQueue {
    public enum Kind: Sendable, Equatable {
        case transcribe
        case reTranscribe
    }

    public struct Entry: Sendable, Equatable {
        public let meetingID: UUID
        public let kind: Kind

        public init(meetingID: UUID, kind: Kind) {
            self.meetingID = meetingID
            self.kind = kind
        }
    }

    /// Entries not yet started, in run order.
    public private(set) var waiting: [Entry] = []

    /// The entry currently running, if any.
    public private(set) var running: Entry?

    private let runner: @MainActor (Entry) async -> Void
    private var worker: Task<Void, Never>?

    public init(runner: @escaping @MainActor (Entry) async -> Void) {
        self.runner = runner
    }

    /// Appends unless the meeting is already waiting or running (no-op then).
    public func enqueue(_ meetingID: UUID, kind: Kind) {
        guard !isActive(meetingID) else { return }
        waiting.append(Entry(meetingID: meetingID, kind: kind))
        startIfNeeded()
    }

    /// Drops a WAITING entry for the meeting (no effect on a running one).
    public func remove(_ meetingID: UUID) {
        waiting.removeAll { $0.meetingID == meetingID }
    }

    /// True when the meeting has a waiting (not yet running) entry.
    public func isWaiting(_ meetingID: UUID) -> Bool {
        waiting.contains { $0.meetingID == meetingID }
    }

    /// True when the meeting is waiting or running.
    public func isActive(_ meetingID: UUID) -> Bool {
        isWaiting(meetingID) || running?.meetingID == meetingID
    }

    /// Test seam: returns once the queue is empty and idle.
    package func awaitIdle() async {
        while let current = worker {
            await current.value
            // Re-check: new work may have been enqueued during the await.
        }
    }

    private func startIfNeeded() {
        guard worker == nil, !waiting.isEmpty else { return }
        // Promote synchronously so `running` and `isActive` are correct
        // for callers that check state right after enqueue().
        let entry = waiting.removeFirst()
        running = entry
        worker = Task { @MainActor [weak self] in
            guard let self else { return }
            await runner(entry)
            running = nil
            worker = nil
            startIfNeeded()
        }
    }
}
