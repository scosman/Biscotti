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
///
/// A catalog model that isn't on disk skips its test cases (with a printed
/// SKIPPED line) and fails each suite's presence test once, via
/// ``expectAllCatalogModelsOnDisk()``, so a partial run can't pass silently.
struct AITestModel: Sendable, CustomTestStringConvertible {
    let name: String
    let path: URL
    /// Where the model comes from; nil for an `LLM_MODEL_PATH` override.
    let downloadURL: URL?

    var testDescription: String {
        name
    }

    /// The `LLM_MODEL_PATH` override, if set.
    static let overridePath = ProcessInfo.processInfo.environment["LLM_MODEL_PATH"]

    static let all: [AITestModel] = {
        if let overridePath = AITestModel.overridePath {
            let path = URL(fileURLWithPath: (overridePath as NSString).expandingTildeInPath)
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

    /// Where the model should be and how to get it.
    private var missingDescription: String {
        var description = "\(name): not on disk at \(path.path)."
        if let downloadURL {
            description += " Download it first: in Biscotti (Settings → AI Enhancements), or "
                + "`swift run --package-path Packages/LocalLLM localllm download --url \(downloadURL.absoluteString)`."
        }
        return description
    }

    /// Reports why this model's test case is not running. A missing catalog model
    /// only prints a SKIPPED line here: ``expectAllCatalogModelsOnDisk()`` records
    /// the one failure for it. A missing `LLM_MODEL_PATH` file fails here.
    func reportMissing() {
        guard downloadURL != nil else {
            Issue.record("LLM_MODEL_PATH points at \(path.path), which is not on disk.")
            return
        }
        print("[AI tests] SKIPPED \(missingDescription)")
    }

    /// Records one failure naming every catalog model that isn't on disk, with its
    /// path and download instructions. The presence tests that call this are
    /// disabled under `LLM_MODEL_PATH`, a deliberate single-model run; the guard
    /// below keeps it a no-op there too.
    static func expectAllCatalogModelsOnDisk() {
        guard overridePath == nil else { return }
        let missing = all.filter { !$0.isOnDisk }
        guard !missing.isEmpty else { return }
        let details = missing.map { "- \($0.missingDescription)" }.joined(separator: "\n")
        Issue.record("""
        \(missing.count) catalog model(s) not on disk, so their AI tests were skipped. \
        test-ai must cover every model in LLMModelCatalog.all:
        \(details)
        """)
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
    /// Returns nil (after reporting why) when the model is not on disk.
    static func connection(
        for model: AITestModel,
        config: EngineConfig = EngineConfig(contextSize: 4096, seed: 42)
    ) async throws -> LLMConnection? {
        if let loaded = current.withLock({ $0 }), loaded.modelName == model.name {
            return loaded.connection
        }
        guard model.isOnDisk else {
            model.reportMissing()
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
