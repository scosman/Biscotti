import Foundation
import LiveTranscriptModel
import os.log
import Synchronization

/// Carries the worker's live updates to the stream of the client's current
/// live session, and ends that stream when the session ends.
///
/// The worker's callbacks arrive on an XPC queue, outside the `Transcriber`
/// actor, so the current session sits behind a lock.
final class LiveUpdateRoute: Sendable {
    private static let log = Logger(subsystem: "net.scosman.biscotti", category: "live")

    private struct Session {
        let id: UUID
        let generation: Int
        let continuation: AsyncStream<LiveTrackUpdate>.Continuation
    }

    private let current = Mutex<Session?>(nil)

    /// Routes a new session's updates to a new stream; the earlier session's
    /// stream ends.
    func begin(sessionID: UUID, generation: Int) -> AsyncStream<LiveTrackUpdate> {
        let (stream, continuation) = AsyncStream.makeStream(of: LiveTrackUpdate.self, bufferingPolicy: .unbounded)
        let previous = current.withLock { session in
            defer { session = Session(id: sessionID, generation: generation, continuation: continuation) }
            return session
        }
        previous?.continuation.finish()
        return stream
    }

    /// Whether this session's stream is still open.
    func isCurrent(sessionID: UUID, generation: Int) -> Bool {
        current.withLock { $0?.id == sessionID && $0?.generation == generation }
    }

    /// Yields a JSON `LiveTrackUpdate` when it belongs to the current session
    /// and generation. Anything else is from an earlier session and is dropped.
    func deliver(_ updateData: Data) {
        guard let update = try? JSONDecoder().decode(LiveTrackUpdate.self, from: updateData) else {
            Self.log.error("Dropped a live update that did not decode (\(updateData.count, privacy: .public) bytes)")
            return
        }
        current.withLock { session in
            guard let session, session.id == update.sessionID, session.generation == update.generation else { return }
            session.continuation.yield(update)
        }
    }

    /// Ends the stream of this session, if it is the current one.
    func end(sessionID: UUID, generation: Int) {
        let ended = current.withLock { session -> Session? in
            guard let open = session, open.id == sessionID, open.generation == generation else { return nil }
            session = nil
            return open
        }
        ended?.continuation.finish()
    }

    /// Ends whatever session is current: the worker was interrupted.
    func endCurrent() {
        let ended = current.withLock { session in
            defer { session = nil }
            return session
        }
        ended?.continuation.finish()
    }
}

/// Counts each track's chunks sent to the worker and not yet acknowledged.
final class LiveChunkWindow: Sendable {
    /// Two seconds of 250 ms chunks per track (architecture: bounded buffering).
    static let limit = 8

    private let inTransit = Mutex<[LiveTrack: Int]>([:])

    /// Takes a slot for one chunk of `track`, or returns false when all are taken.
    func reserve(_ track: LiveTrack) -> Bool {
        inTransit.withLock { counts in
            guard counts[track, default: 0] < Self.limit else { return false }
            counts[track, default: 0] += 1
            return true
        }
    }

    func release(_ track: LiveTrack) {
        inTransit.withLock { counts in
            counts[track] = max(0, counts[track, default: 0] - 1)
        }
    }
}

/// Resumes a continuation once, from whichever comes first: the reply, or
/// the error handler of a proxy from `remoteObjectProxy(errorHandler:)`.
final class ReplyOnce<Value: Sendable>: Sendable {
    private let continuation: Mutex<CheckedContinuation<Value, any Error>?>

    init(_ continuation: CheckedContinuation<Value, any Error>) {
        self.continuation = Mutex(continuation)
    }

    func resume(with result: Result<Value, any Error>) {
        let pending = continuation.withLock { stored in
            defer { stored = nil }
            return stored
        }
        pending?.resume(with: result)
    }

    func resume(returning value: Value) {
        resume(with: .success(value))
    }

    func resume(throwing error: any Error) {
        resume(with: .failure(error))
    }
}
