import Foundation

/// A single-shot future for a file URL delivered by a file-promise callback.
/// Supports awaiting before or after resolution.
///
/// One instance per `NSFilePromiseReceiver`. The receiver's callback
/// resolves the future; the import-entry's `deliver` closure awaits it.
final class PromisedFile: @unchecked Sendable {
    private enum State {
        case pending(CheckedContinuation<URL, Error>?)
        case resolved(Result<URL, Error>)
    }

    /// Guards `state` for thread safety (callbacks arrive on a serial
    /// OperationQueue, awaits on any executor).
    private let lock = NSLock()
    private var state: State = .pending(nil)

    /// Awaits the delivered file URL, or throws if delivery failed.
    var value: URL {
        get async throws {
            try await withCheckedThrowingContinuation { continuation in
                lock.lock()
                switch state {
                case .pending(nil):
                    // Not yet resolved -- park the continuation.
                    state = .pending(continuation)
                    lock.unlock()
                case .pending:
                    // Should never happen: only one awaiter.
                    lock.unlock()
                    continuation.resume(
                        throwing: PromisedFileError.multipleAwaiters
                    )
                case let .resolved(result):
                    // Already resolved before we awaited.
                    lock.unlock()
                    continuation.resume(with: result)
                }
            }
        }
    }

    /// Resolves the future with a delivered URL or an error.
    /// Called from the promise receiver's callback.
    func resolve(url: URL?, error: Error?) {
        let result: Result<URL, Error> = if let error {
            .failure(error)
        } else if let url {
            .success(url)
        } else {
            .failure(PromisedFileError.noFileDelivered)
        }

        lock.lock()
        switch state {
        case let .pending(continuation):
            state = .resolved(result)
            lock.unlock()
            continuation?.resume(with: result)
        case .resolved:
            // Already resolved (extra callback). Ignore.
            lock.unlock()
        }
    }
}

enum PromisedFileError: Error {
    case noFileDelivered
    case multipleAwaiters
}
