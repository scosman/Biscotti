import LocalLLM
import Testing
@testable import Intelligence

// MARK: - Helpers

private let oneGB: UInt64 = 1_000_000_000
private let catalog = LLMModelCatalog.all

// Catalog entries by index -- 12B is first, E2B is second (display order).
// Using index access avoids force-unwrapping the optional `model(id:)` lookup
// at file scope where `try #require` is unavailable.
private let model12B = LLMModelCatalog.all[0]
private let modelE2B = LLMModelCatalog.all[1]

// MARK: - canRun tests

@Suite("ModelSuitability.canRun")
struct CanRunTests {
    @Test(
        "12B: RAM boundary (15 GB floor)",
        arguments: [
            (ram: 8 * oneGB, expected: false),
            (ram: 14 * oneGB, expected: false),
            (ram: 15 * oneGB - 1, expected: false),
            (ram: 15 * oneGB, expected: true),
            (ram: 16 * oneGB, expected: true),
            (ram: 24 * oneGB, expected: true),
            (ram: 64 * oneGB, expected: true)
        ]
    )
    func canRun12B(ram: UInt64, expected: Bool) {
        #expect(ModelSuitability.canRun(model12B, ram: ram) == expected)
    }

    @Test(
        "E2B: always runnable",
        arguments: [
            8 * oneGB,
            16 * oneGB,
            64 * oneGB
        ]
    )
    func canRunE2B(ram: UInt64) {
        #expect(ModelSuitability.canRun(modelE2B, ram: ram) == true)
    }
}

// MARK: - recommendedModelID tests

@Suite("ModelSuitability.recommendedModelID")
struct RecommendedModelIDTests {
    @Test(
        "below 24 GB recommends E2B",
        arguments: [
            8 * oneGB,
            15 * oneGB,
            16 * oneGB,
            24 * oneGB - 1
        ]
    )
    func below24GBRecommendsE2B(ram: UInt64) {
        let recommended = ModelSuitability.recommendedModelID(
            catalog: catalog, ram: ram
        )
        #expect(recommended == "gemma-4-e2b")
    }

    @Test("at 24 GB recommends 12B")
    func at24GBRecommends12B() {
        let recommended = ModelSuitability.recommendedModelID(
            catalog: catalog, ram: 24 * oneGB
        )
        #expect(recommended == "gemma-4-12b")
    }

    @Test("above 24 GB recommends 12B")
    func above24GBRecommends12B() {
        let recommended = ModelSuitability.recommendedModelID(
            catalog: catalog, ram: 64 * oneGB
        )
        #expect(recommended == "gemma-4-12b")
    }

    @Test("empty catalog returns nil")
    func emptyCatalogReturnsNil() {
        let recommended = ModelSuitability.recommendedModelID(
            catalog: [], ram: 64 * oneGB
        )
        #expect(recommended == nil)
    }

    @Test("never recommends a non-runnable model")
    func neverRecommendsNonRunnable() throws {
        // At every tested RAM level, the recommended model must pass canRun.
        for ram in [8, 12, 15, 16, 24, 32, 64].map({ UInt64($0) * oneGB }) {
            guard let id = ModelSuitability.recommendedModelID(
                catalog: catalog, ram: ram
            ) else { continue }
            let model = try #require(LLMModelCatalog.model(id: id))
            #expect(
                ModelSuitability.canRun(model, ram: ram),
                "Recommended \(id) at \(ram / oneGB) GB but it is not runnable"
            )
        }
    }
}

// MARK: - hasEnoughDisk tests

@Suite("ModelSuitability.hasEnoughDisk")
struct HasEnoughDiskTests {
    @Test("nil freeBytes returns true (never block on unknown)")
    func nilFreeBytesReturnsTrue() {
        #expect(ModelSuitability.hasEnoughDisk(model12B, freeBytes: nil) == true)
        #expect(ModelSuitability.hasEnoughDisk(modelE2B, freeBytes: nil) == true)
    }

    @Test(
        "12B disk boundaries (7 GB required)",
        arguments: [
            (free: Int64(0), expected: false),
            (free: Int64(7_000_000_000 - 1), expected: false),
            (free: Int64(7_000_000_000), expected: true),
            (free: Int64(20_000_000_000), expected: true)
        ]
    )
    func disk12B(free: Int64, expected: Bool) {
        #expect(ModelSuitability.hasEnoughDisk(model12B, freeBytes: free) == expected)
    }

    @Test(
        "E2B disk boundaries (3 GB required)",
        arguments: [
            (free: Int64(0), expected: false),
            (free: Int64(3_000_000_000 - 1), expected: false),
            (free: Int64(3_000_000_000), expected: true),
            (free: Int64(10_000_000_000), expected: true)
        ]
    )
    func diskE2B(free: Int64, expected: Bool) {
        #expect(ModelSuitability.hasEnoughDisk(modelE2B, freeBytes: free) == expected)
    }
}

// MARK: - ModelPolicy tests

@Suite("ModelPolicy")
struct ModelPolicyTests {
    @Test("description is non-empty for known model IDs")
    func descriptionKnownIDs() {
        #expect(!ModelPolicy.description(id: "gemma-4-12b").isEmpty)
        #expect(!ModelPolicy.description(id: "gemma-4-e2b").isEmpty)
    }

    @Test("description is empty for unknown model ID")
    func descriptionUnknownID() {
        #expect(ModelPolicy.description(id: "unknown-model").isEmpty)
    }

    @Test("minRAMBytesToRun: 12B has floor, E2B is 0")
    func minRAMBytesToRun() {
        #expect(ModelPolicy.minRAMBytesToRun(id: "gemma-4-12b") == 15_000_000_000)
        #expect(ModelPolicy.minRAMBytesToRun(id: "gemma-4-e2b") == 0)
        #expect(ModelPolicy.minRAMBytesToRun(id: "unknown") == 0)
    }

    @Test("approxRAMUsageDescription for known IDs")
    func approxRAMUsage() {
        #expect(ModelPolicy.approxRAMUsageDescription(id: "gemma-4-12b") == "8 GB")
        #expect(ModelPolicy.approxRAMUsageDescription(id: "gemma-4-e2b") == "4 GB")
    }

    @Test("threshold constants have expected values")
    func thresholdConstants() {
        #expect(ModelPolicy.ramFloor12B == 15_000_000_000)
        #expect(ModelPolicy.recommendationRAMThreshold == 24_000_000_000)
    }
}
