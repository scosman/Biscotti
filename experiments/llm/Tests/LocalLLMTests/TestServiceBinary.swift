import Foundation
@testable import LocalLLM

// MARK: - Shared test helper: resolve the localllm-service binary

/// Resolve the `localllm-service` binary for tests.
///
/// SPM test runners (`xctest`, Swift Testing host) run from a system path, NOT
/// from next to the built products, so `RemoteBackend.resolveServiceBinary()`'s
/// Bundle/argv walk-up fails. This helper adds a `#filePath`-based fallback that
/// locates the binary inside `.build/<triple>/debug/` relative to the package root.
///
/// Both `TransportTests` and `IntegrationTests` use this single resolver to avoid
/// duplicated logic.
enum TestServiceBinary {
    /// Resolve the binary URL, or nil if not built.
    ///
    /// Tries the `#filePath`-based `.build/` lookup first (most reliable under
    /// the SPM test runner), then falls back to the production resolver.
    static func resolve() -> URL? {
        // Primary: derive the package root from this source file's location.
        // #filePath → .../experiments/llm/Tests/LocalLLMTests/TestServiceBinary.swift
        // packageRoot → .../experiments/llm/
        let thisFile = URL(fileURLWithPath: #filePath)
        let packageRoot = thisFile
            .deletingLastPathComponent() // LocalLLMTests/
            .deletingLastPathComponent() // Tests/
            .deletingLastPathComponent() // llm/

        let binaryName = "localllm-service"
        let fm = FileManager.default
        let candidates = [
            packageRoot.appendingPathComponent(".build/arm64-apple-macosx/debug/\(binaryName)"),
            packageRoot.appendingPathComponent(".build/debug/\(binaryName)"),
            packageRoot.appendingPathComponent(".build/x86_64-apple-macosx/debug/\(binaryName)"),
        ]
        for candidate in candidates {
            if fm.fileExists(atPath: candidate.path) {
                return candidate
            }
        }

        // Fallback: production resolver (works when running from the CLI binary
        // itself, or when LOCALLLM_SERVICE_PATH is set to a valid executable).
        if let url = RemoteBackend.resolveServiceBinary() {
            return url
        }

        return nil
    }

    /// Whether the binary is available (for `.enabled(if:)` guards).
    static let isAvailable: Bool = resolve() != nil

    /// Resolve or throw a descriptive error.
    static func require() throws -> URL {
        guard let url = resolve() else {
            throw ServiceBinaryNotFound()
        }
        return url
    }

    struct ServiceBinaryNotFound: Error, CustomStringConvertible {
        let description = "localllm-service binary not found -- run build_llm first"
    }
}
