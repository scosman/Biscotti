import Foundation
@testable import STTLabHome
import Testing

@Suite("ProductionSettings drift detection")
struct ProductionSettingsTests {
    /// Asserts that the copied model name matches the production source in MethodResolver.swift.
    /// This test reads the source file via #filePath-relative navigation, so it catches
    /// drift if someone updates the production constant without updating ProductionSettings.
    @Test("sttModel matches MethodResolver.swift")
    func driftTest() throws {
        // Navigate from this test file to the production source.
        // This file: experiments/STTLab/Tests/STTLabHomeTests/ProductionSettingsTests.swift
        // Target:    Packages/Transcription/Sources/Transcription/MethodResolver.swift
        let thisFile = URL(fileURLWithPath: #filePath)
        let repoRoot = thisFile
            .deletingLastPathComponent() // STTLabHomeTests
            .deletingLastPathComponent() // Tests
            .deletingLastPathComponent() // STTLab
            .deletingLastPathComponent() // experiments
            .deletingLastPathComponent() // repo root

        let methodResolverPath = repoRoot
            .appendingPathComponent("Packages/Transcription/Sources/Transcription/MethodResolver.swift")

        let source = try String(contentsOf: methodResolverPath, encoding: .utf8)

        // The production source defines: static let sttModel = "openai_whisper-large-v3-v20240930_626MB"
        let modelFound = source.contains("\"\(ProductionSettings.sttModel)\"")
        #expect(modelFound, "ProductionSettings.sttModel not found in MethodResolver.swift")

        // Also verify the repo name.
        let repoFound = source.contains("\"\(ProductionSettings.sttModelRepo)\"")
        #expect(repoFound, "ProductionSettings.sttModelRepo not found in MethodResolver.swift")
    }
}
