import LlamaSwift
import Synchronization

/// Process-level lifecycle for the llama.cpp backend.
///
/// `llama_backend_init()` is called once per process (lazily, by `LLMEngine.init`).
/// `shutdown()` tears it down — call it **once**, at end-of-process, **after** every
/// `LLMEngine` has been `unload()`-ed or deallocated. It is not safe to create new
/// engines after shutdown.
///
/// A long-running app (e.g. Project 10) should call `shutdown()` only in its
/// `applicationWillTerminate` / exit handler — never mid-session.
///
/// ## Why this exists
///
/// llama.cpp's Metal backend allocates a global device with GPU residency sets.
/// If `llama_backend_free()` is never called, the device's C++ static destructor
/// fires during `__cxa_finalize_ranges` at `exit()` and asserts that the residency
/// sets are empty — but they aren't, because no one freed them. The result is
/// `GGML_ASSERT([rsets->data count] == 0) failed` → SIGABRT after the program's
/// work is complete. Calling `llama_backend_free()` explicitly, in the right order
/// (after all contexts/models are freed), tears down the Metal device cleanly.
///
/// See: upstream llama.cpp ggml-metal-device.m (`ggml_metal_rsets_free`).
public enum LocalLLMRuntime {
    /// Whether `shutdown()` has been called.
    private static let hasShutDown = Mutex(false)

    /// Tear down the llama.cpp backend (ggml, Metal device, residency sets).
    ///
    /// - **Precondition:** all `LLMEngine` instances must have been unloaded or
    ///   deallocated before calling this. Calling shutdown while an engine holds
    ///   a live context/model is undefined behavior.
    /// - Safe to call multiple times (idempotent); only the first call has effect.
    /// - Safe to call even if no engine was ever created (backend_free is a no-op
    ///   when backend_init was never called).
    public static func shutdown() {
        let alreadyDone = hasShutDown.withLock { done in
            if done { return true }
            done = true
            return false
        }
        guard !alreadyDone else { return }
        llama_backend_free()
    }

    /// Whether the runtime has been shut down. Primarily for testing.
    internal static var isShutDown: Bool {
        hasShutDown.withLock { $0 }
    }

    // Reset for testing only — allows shutdown() to fire again in the same process.
    // Not public; tests use @testable import.
    internal static func _resetForTesting() {
        hasShutDown.withLock { $0 = false }
    }
}
