import Foundation
import Testing
@testable import LocalLLM

// .serialized: these tests mutate process-global state (the backend shutdown flag)
// and must not run concurrently with each other.
//
// .disabled when BISCOTTI_RUN_AI_TESTS=1: in AI-test mode, IntegrationTests holds
// a LIVE in-process model. RuntimeTests calls the real `llama_backend_free()` (via
// LocalLLMRuntime.shutdown()), which frees the Metal device under that live model —
// and `backendInitOnce` is one-shot, so the backend can't be re-initialized.
// Coverage is fully preserved by the non-AI `make test` run (no model loaded, so
// backend_free is a harmless no-op).
@Suite(
    "LocalLLMRuntime",
    .serialized,
    .disabled(if: ProcessInfo.processInfo.environment["BISCOTTI_RUN_AI_TESTS"] == "1")
)
struct RuntimeTests {
    /// shutdown() is idempotent — calling it twice does not crash.
    @Test("shutdown is idempotent")
    func shutdownIdempotent() {
        // Reset so we start from a known state.
        LocalLLMRuntime._resetForTesting()
        #expect(!LocalLLMRuntime.isShutDown)

        LocalLLMRuntime.shutdown()
        #expect(LocalLLMRuntime.isShutDown)

        // Second call should be a no-op (no crash, no double-free).
        LocalLLMRuntime.shutdown()
        #expect(LocalLLMRuntime.isShutDown)

        // Clean up for other tests that may need the backend.
        LocalLLMRuntime._resetForTesting()
    }

    /// _resetForTesting re-enables shutdown.
    @Test("resetForTesting clears the shutdown flag")
    func resetForTesting() {
        LocalLLMRuntime._resetForTesting()
        #expect(!LocalLLMRuntime.isShutDown)

        LocalLLMRuntime.shutdown()
        #expect(LocalLLMRuntime.isShutDown)

        LocalLLMRuntime._resetForTesting()
        #expect(!LocalLLMRuntime.isShutDown)
    }
}
