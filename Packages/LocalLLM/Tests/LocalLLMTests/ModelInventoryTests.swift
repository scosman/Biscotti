import Foundation
import Testing
@testable import LocalLLM

@Suite("ModelInventory")
struct ModelInventoryTests {
    /// Creates a fresh temp directory for each test.
    private func makeTempDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("inventory-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private func cleanup(_ dir: URL) {
        try? FileManager.default.removeItem(at: dir)
    }

    /// A small test model descriptor (not a real download).
    private var testModel: LLMModel {
        LLMModel(
            id: "test-model",
            displayName: "Test Model",
            downloadURL: URL(string: "https://example.com/test.gguf")!,
            fileName: "test.gguf",
            approxDownloadBytes: 100
        )
    }

    private var otherModel: LLMModel {
        LLMModel(
            id: "other-model",
            displayName: "Other Model",
            downloadURL: URL(string: "https://example.com/other.gguf")!,
            fileName: "other.gguf",
            approxDownloadBytes: 200
        )
    }

    // MARK: - path(for:)

    @Test("path(for:) composes cacheDirectory + model.fileName")
    func pathComposition() {
        let dir = URL(fileURLWithPath: "/tmp/test-cache")
        let inventory = ModelInventory(cacheDirectory: dir)
        let path = inventory.path(for: testModel)
        #expect(path == dir.appendingPathComponent("test.gguf"))
    }

    // MARK: - isDownloaded

    @Test("isDownloaded returns true for non-empty regular file")
    func isDownloadedTrue() throws {
        let dir = try makeTempDir()
        defer { cleanup(dir) }

        let inventory = ModelInventory(cacheDirectory: dir)
        let modelPath = inventory.path(for: testModel)
        try Data([0x42, 0x43]).write(to: modelPath)

        #expect(inventory.isDownloaded(testModel) == true)
    }

    @Test("isDownloaded returns false for missing file")
    func isDownloadedMissing() throws {
        let dir = try makeTempDir()
        defer { cleanup(dir) }

        let inventory = ModelInventory(cacheDirectory: dir)
        #expect(inventory.isDownloaded(testModel) == false)
    }

    @Test("isDownloaded returns false for empty file")
    func isDownloadedEmpty() throws {
        let dir = try makeTempDir()
        defer { cleanup(dir) }

        let inventory = ModelInventory(cacheDirectory: dir)
        FileManager.default.createFile(
            atPath: inventory.path(for: testModel).path,
            contents: Data()
        )

        #expect(inventory.isDownloaded(testModel) == false)
    }

    @Test("isDownloaded returns false for a directory at the model path")
    func isDownloadedDirectory() throws {
        let dir = try makeTempDir()
        defer { cleanup(dir) }

        let inventory = ModelInventory(cacheDirectory: dir)
        try FileManager.default.createDirectory(
            at: inventory.path(for: testModel),
            withIntermediateDirectories: true
        )

        #expect(inventory.isDownloaded(testModel) == false)
    }

    // MARK: - downloadedModels(in:)

    @Test("downloadedModels filters to only downloaded models")
    func downloadedModelsFiltering() throws {
        let dir = try makeTempDir()
        defer { cleanup(dir) }

        let inventory = ModelInventory(cacheDirectory: dir)

        // Only testModel is "downloaded"
        try Data([0x42]).write(to: inventory.path(for: testModel))

        let catalog = [testModel, otherModel]
        let downloaded = inventory.downloadedModels(in: catalog)

        #expect(downloaded.count == 1)
        #expect(downloaded.first?.id == testModel.id)
    }

    @Test("downloadedModels returns empty when nothing downloaded")
    func downloadedModelsEmpty() throws {
        let dir = try makeTempDir()
        defer { cleanup(dir) }

        let inventory = ModelInventory(cacheDirectory: dir)
        let downloaded = inventory.downloadedModels(in: [testModel, otherModel])

        #expect(downloaded.isEmpty)
    }

    @Test("downloadedModels preserves catalog order")
    func downloadedModelsOrder() throws {
        let dir = try makeTempDir()
        defer { cleanup(dir) }

        let inventory = ModelInventory(cacheDirectory: dir)

        // Download both
        try Data([0x42]).write(to: inventory.path(for: testModel))
        try Data([0x42]).write(to: inventory.path(for: otherModel))

        let catalog = [otherModel, testModel] // reversed order
        let downloaded = inventory.downloadedModels(in: catalog)

        #expect(downloaded.count == 2)
        #expect(downloaded[0].id == otherModel.id)
        #expect(downloaded[1].id == testModel.id)
    }

    // MARK: - delete

    @Test("delete removes the model file and its .partial sibling")
    func deleteRemovesFileAndPartial() throws {
        let dir = try makeTempDir()
        defer { cleanup(dir) }

        let inventory = ModelInventory(cacheDirectory: dir)
        let modelPath = inventory.path(for: testModel)
        let partialPath = ModelDownloader.tempPath(for: modelPath)

        // Create both files
        try Data([0x42]).write(to: modelPath)
        try Data([0x43]).write(to: partialPath)

        #expect(FileManager.default.fileExists(atPath: modelPath.path))
        #expect(FileManager.default.fileExists(atPath: partialPath.path))

        try inventory.delete(testModel)

        #expect(!FileManager.default.fileExists(atPath: modelPath.path))
        #expect(!FileManager.default.fileExists(atPath: partialPath.path))
    }

    @Test("delete of a missing file does not throw")
    func deleteMissingNoThrow() throws {
        let dir = try makeTempDir()
        defer { cleanup(dir) }

        let inventory = ModelInventory(cacheDirectory: dir)

        // Should not throw -- idempotent
        try inventory.delete(testModel)
    }

    @Test("delete removes only the .partial when the main file is already gone")
    func deletePartialOnly() throws {
        let dir = try makeTempDir()
        defer { cleanup(dir) }

        let inventory = ModelInventory(cacheDirectory: dir)
        let modelPath = inventory.path(for: testModel)
        let partialPath = ModelDownloader.tempPath(for: modelPath)

        // Only partial exists
        try Data([0x43]).write(to: partialPath)
        #expect(FileManager.default.fileExists(atPath: partialPath.path))

        try inventory.delete(testModel)

        #expect(!FileManager.default.fileExists(atPath: partialPath.path))
    }

    @Test("isDownloaded returns false after delete")
    func isDownloadedAfterDelete() throws {
        let dir = try makeTempDir()
        defer { cleanup(dir) }

        let inventory = ModelInventory(cacheDirectory: dir)
        try Data([0x42]).write(to: inventory.path(for: testModel))

        #expect(inventory.isDownloaded(testModel) == true)
        try inventory.delete(testModel)
        #expect(inventory.isDownloaded(testModel) == false)
    }
}
