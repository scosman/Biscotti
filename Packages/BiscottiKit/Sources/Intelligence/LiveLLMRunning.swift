import Foundation
import LocalLLM

/// Production `LLMRunning` backed by `LLMService.withConnection` using the
/// hosted (XPC) backend. Each `withSession` call opens a connection, loads the
/// model, runs the closure, and closes the connection.
public struct LiveLLMRunner: LLMRunning {
    private let modelProvider: any ModelProviding

    /// The XPC service bundle identifier for BiscottiLLM.
    static let serviceName = "net.scosman.biscotti.BiscottiLLM"

    public init(modelProvider: any ModelProviding) {
        self.modelProvider = modelProvider
    }

    public func withSession<T: Sendable>(
        config: EngineConfig,
        _ body: @Sendable (any LLMSession) async throws -> T
    ) async throws -> T {
        try await LLMService.withConnection(
            model: modelProvider.modelURL,
            backend: .hosted(serviceName: Self.serviceName),
            config: config
        ) { connection in
            try await body(LiveLLMSession(connection: connection))
        }
    }
}

/// Production `LLMSession` wrapping a live `LLMConnection`.
struct LiveLLMSession: LLMSession, @unchecked Sendable {
    let connection: LLMConnection

    func countTokens(
        system: String, user: String
    ) async throws -> Int {
        try await connection.countTokens(system: system, user: user)
    }

    func reconfigure(contextSize: Int) async throws {
        try await connection.reconfigure(contextSize: contextSize)
    }

    func generate(
        system: String, user: String, options: GenerationOptions
    ) async throws -> String {
        let result = try await connection.generate(
            prompt: user, system: system, options: options
        )
        return result.text
    }

    func generateStreaming(
        system: String, user: String, options: GenerationOptions
    ) async -> AsyncThrowingStream<StreamEvent, Error> {
        await connection.generateStreaming(
            prompt: user, system: system, options: options
        )
    }
}
