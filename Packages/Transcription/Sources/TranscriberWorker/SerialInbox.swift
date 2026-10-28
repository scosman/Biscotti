/// Runs work one item at a time, in the order it was added.
///
/// NSXPC delivers one connection's messages in order, but a `Task` started
/// for each message may reach the `EngineHost` in any order. Live chunks,
/// and finish after the last chunk, must keep theirs.
final class SerialInbox: Sendable {
    typealias Work = @Sendable () async -> Void

    private let continuation: AsyncStream<Work>.Continuation

    init(priority: TaskPriority = .userInitiated) {
        let (work, continuation) = AsyncStream.makeStream(of: Work.self, bufferingPolicy: .unbounded)
        self.continuation = continuation
        Task(priority: priority) {
            for await item in work {
                await item()
            }
        }
    }

    func add(_ work: @escaping Work) {
        continuation.yield(work)
    }

    /// Runs what was added and stops; work added later is dropped.
    func close() {
        continuation.finish()
    }
}
