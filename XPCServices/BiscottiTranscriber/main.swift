import Foundation
import Transcription

// MARK: - Sendable box

/// Wraps a non-`Sendable` value so it can cross into a `@Sendable` closure.
/// Used here for the NSXPC remote-object proxy, which is thread-safe at runtime
/// but not statically `Sendable`.
private struct UncheckedSendableBox<T>: @unchecked Sendable {
    let value: T
    init(_ value: T) {
        self.value = value
    }
}

// MARK: - Exported object

/// The exported object vended to XPC clients. Bridges the `@objc`
/// reply-handler protocol to the async `InProcessTranscriptionEngine`.
///
/// Thread-safety: the only mutable state is `engine`, which is an actor.
/// All access goes through `await`, so `@unchecked Sendable` is safe.
final class TranscriberService: NSObject, TranscriberServiceProtocol, @unchecked Sendable {
    private let engine = InProcessTranscriptionEngine()

    /// The owning connection, used to reach the client's status callback.
    /// Weak to avoid a retain cycle (the connection retains this exported
    /// object). If the connection is torn down mid-download the proxy obtained
    /// from it simply drops further fire-and-forget status messages — there is
    /// no use-after-free, since NSXPC proxies tolerate a dead connection.
    private weak var connection: NSXPCConnection?

    init(connection: NSXPCConnection?) {
        self.connection = connection
        super.init()
    }

    func processAudio(
        requestData: Data,
        reply: @escaping @Sendable (Data?, (any Error)?) -> Void
    ) {
        let request: XPCProcessRequest
        do {
            request = try JSONDecoder().decode(XPCProcessRequest.self, from: requestData)
        } catch {
            reply(nil, error)
            return
        }

        let engine = engine
        Task {
            do {
                let result = try await engine.processAudio(
                    micPath: request.micPath,
                    systemPath: request.systemPath,
                    customVocabulary: request.customVocabulary,
                    diarizationClusterThreshold: request.diarizationClusterThreshold
                )
                let data = try JSONEncoder().encode(result)
                reply(data, nil)
            } catch {
                reply(nil, error)
            }
        }
    }

    func ensureModelsDownloaded(
        reply: @escaping @Sendable ((any Error)?) -> Void
    ) {
        let engine = engine
        // Grab the client's status callback proxy now (on the XPC queue) and
        // box it so it can cross into the @Sendable Task. NSXPC proxies are
        // thread-safe; the box documents the unchecked assumption. Status
        // calls are fire-and-forget (no reply), so a dropped update is harmless.
        let statusBox = UncheckedSendableBox(
            connection?.remoteObjectProxy as? TranscriberStatusReporting
        )
        Task {
            do {
                try await engine.ensureModelsDownloaded { status in
                    statusBox.value?.reportDownloadStatus(status)
                }
                reply(nil)
            } catch {
                reply(error)
            }
        }
    }

    func unloadModels(reply: @escaping @Sendable () -> Void) {
        let engine = engine
        Task {
            await engine.unloadModels()
            reply()
        }
    }

    func healthCheck(reply: @escaping @Sendable (Bool) -> Void) {
        reply(true)
    }
}

// MARK: - Listener delegate

final class ServiceDelegate: NSObject, NSXPCListenerDelegate {
    func listener(
        _: NSXPCListener,
        shouldAcceptNewConnection connection: NSXPCConnection
    ) -> Bool {
        connection.exportedInterface = NSXPCInterface(
            with: TranscriberServiceProtocol.self
        )
        // The client exports a status receiver; declare its interface so we
        // can obtain a proxy to push download status back during downloads.
        connection.remoteObjectInterface = NSXPCInterface(
            with: TranscriberStatusReporting.self
        )
        connection.exportedObject = TranscriberService(connection: connection)
        connection.resume()
        return true
    }
}

// MARK: - Entry point

let delegate = ServiceDelegate()
let listener = NSXPCListener.service()
listener.delegate = delegate
listener.resume()
