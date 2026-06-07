import Foundation
import Transcription

// MARK: - Exported object

/// The exported object vended to XPC clients. Bridges the `@objc`
/// reply-handler protocol to the async `InProcessTranscriptionEngine`.
///
/// Thread-safety: the only mutable state is `engine`, which is an actor.
/// All access goes through `await`, so `@unchecked Sendable` is safe.
final class TranscriberService: NSObject, TranscriberServiceProtocol, @unchecked Sendable {
    private let engine = InProcessTranscriptionEngine()

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
                    customVocabulary: request.customVocabulary
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
        Task {
            do {
                try await engine.ensureModelsDownloaded { _ in }
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
        connection.exportedObject = TranscriberService()
        connection.resume()
        return true
    }
}

// MARK: - Entry point

let delegate = ServiceDelegate()
let listener = NSXPCListener.service()
listener.delegate = delegate
listener.resume()
