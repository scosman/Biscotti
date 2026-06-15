import Testing
@testable import LocalLLM

// .serialized: these tests mutate process-global state (the backend shutdown flag)
// and must not run concurrently with each other.
@Suite("LocalLLMRuntime", .serialized)
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
