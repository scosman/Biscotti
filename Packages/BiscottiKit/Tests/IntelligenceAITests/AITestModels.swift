import Dispatch
import Foundation
import LocalLLM
import Synchronization
import Testing

// Shared by the env-gated AI suites (`BISCOTTI_RUN_AI_TESTS=1`). LocalLLM's
// `LocalLLMTests` target keeps an identical copy: SwiftPM can't share a
// test source file across packages.

/// A model the AI suites run against.
///
/// By default that is every model in `LLMModelCatalog.all`, at the path the app
/// loads it from, so adding a catalog model adds its coverage. `LLM_MODEL_PATH`
/// narrows a run to that one GGUF.
struct AITestModel: Sendable, CustomTestStringConvertible {
    let name: String
    let path: URL
    /// Where the model comes from; nil for an `LLM_MODEL_PATH` override.
    let downloadURL: URL?

    var testDescription: String {
        name
    }

    static let all: [AITestModel] = {
        if let override = ProcessInfo.processInfo.environment["LLM_MODEL_PATH"] {
            let path = URL(fileURLWithPath: (override as NSString).expandingTildeInPath)
            return [AITestModel(name: "LLM_MODEL_PATH (\(path.lastPathComponent))", path: path, downloadURL: nil)]
        }
        let inventory = ModelInventory(cacheDirectory: LocalLLMPaths.defaultModelCacheDir)
        return LLMModelCatalog.all.map { model in
            AITestModel(name: model.displayName, path: inventory.path(for: model), downloadURL: model.downloadURL)
        }
    }()

    var isOnDisk: Bool {
        ModelDownloader.fileExistsAndNonEmpty(at: path)
    }

    /// Records why this model's test case did not run. A catalog model that isn't
    /// downloaded is a known issue (the run still passes, with the message shown); an
    /// `LLM_MODEL_PATH` that doesn't exist is a failure.
    func recordMissing() {
        guard let downloadURL else {
            Issue.record("LLM_MODEL_PATH points at \(path.path), which is not on disk.")
            return
        }
        let message = """
        SKIPPED \(name): not on disk at \(path.path). Download it first: in Biscotti \
        (Settings → AI Enhancements), or `swift run --package-path Packages/LocalLLM \
        localllm download --url \(downloadURL.absoluteString)`.
        """
        print("[AI tests] \(message)")
        withKnownIssue("\(name) is not downloaded") {
            Issue.record("\(message)")
        }
    }
}

/// The one model connection an AI suite holds open. Models are GBs, so only one is
/// loaded at a time: asking for a different model closes the current one first.
enum AITestConnection {
    private struct Loaded: Sendable {
        let modelName: String
        let connection: LLMConnection
    }

    private static let current = Mutex<Loaded?>(nil)

    /// Registers an `atexit` handler exactly once, right after the first model load.
    /// atexit handlers run LIFO, so this runs BEFORE ggml's Metal-device static
    /// destructor (registered during that load). It closes the open connection
    /// (frees ctx/model, drops Metal residency sets), then calls
    /// `llama_backend_free()`. Without it, `exit()` runs ggml's destructor while
    /// residency sets are alive → `GGML_ASSERT([rsets->data count] == 0)` → SIGABRT.
    /// No `_exit()` here: the runner's exit code must survive for `make test-ai`.
    private static let registerAtexitOnce: Void = {
        atexit {
            let sem = DispatchSemaphore(value: 0)
            Task {
                if let loaded = AITestConnection.takeCurrent() {
                    await loaded.connection.close()
                }
                LocalLLMRuntime.shutdown()
                sem.signal()
            }
            // Bounded wait so a stuck teardown can't hang the run forever.
            _ = sem.wait(timeout: .now() + 30.0)
        }
    }()

    /// The open in-process connection for `model`, loading it on first use.
    /// Returns nil (after recording why) when the model is not on disk.
    static func connection(
        for model: AITestModel,
        config: EngineConfig = EngineConfig(contextSize: 4096, seed: 42)
    ) async throws -> LLMConnection? {
        if let loaded = current.withLock({ $0 }), loaded.modelName == model.name {
            return loaded.connection
        }
        guard model.isOnDisk else {
            model.recordMissing()
            return nil
        }
        if let previous = takeCurrent() {
            await previous.connection.close()
        }
        let connection = try await LLMService.openConnection(
            model: model.path, backend: .inProcess, config: config
        )
        current.withLock { $0 = Loaded(modelName: model.name, connection: connection) }
        _ = registerAtexitOnce
        return connection
    }

    private static func takeCurrent() -> Loaded? {
        current.withLock { loaded in
            defer { loaded = nil }
            return loaded
        }
    }
}
