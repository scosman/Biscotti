import Foundation
import Synchronization
import Testing
@testable import LocalLLM

@Suite("ModelDownloader")
struct ModelDownloaderTests {
    @Test("defaultModelURL is well-formed")
    func defaultURL() {
        let url = ModelDownloader.defaultModelURL
        #expect(url.scheme == "https")
        #expect(url.host == "huggingface.co")
        #expect(url.lastPathComponent == "gemma-4-12b-it-UD-Q4_K_XL.gguf")
    }

    @Test("fileExistsAndNonEmpty returns true for non-empty file")
    func fileExistsNonEmpty() throws {
        let tmpDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("llm-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        let file = tmpDir.appendingPathComponent("test.bin")
        try Data([0x42]).write(to: file)
        #expect(ModelDownloader.fileExistsAndNonEmpty(at: file) == true)
    }

    @Test("fileExistsAndNonEmpty returns false for empty file")
    func fileExistsEmpty() throws {
        let tmpDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("llm-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        let file = tmpDir.appendingPathComponent("empty.bin")
        FileManager.default.createFile(atPath: file.path, contents: Data())
        #expect(ModelDownloader.fileExistsAndNonEmpty(at: file) == false)
    }

    @Test("fileExistsAndNonEmpty returns false for missing file")
    func fileNotExists() {
        let file = FileManager.default.temporaryDirectory
            .appendingPathComponent("nonexistent-\(UUID().uuidString).bin")
        #expect(ModelDownloader.fileExistsAndNonEmpty(at: file) == false)
    }

    @Test("fileExistsAndNonEmpty returns false for a directory")
    func fileExistsDirectory() throws {
        // Regression: directories report a non-zero size on APFS/HFS+, so the check must
        // verify the path is a regular file. Without this, a cache directory was mistaken
        // for an already-downloaded model, causing a spurious "Already downloaded" skip.
        let tmpDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("llm-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        #expect(ModelDownloader.fileExistsAndNonEmpty(at: tmpDir) == false)
    }

    @Test("tempPath adds .partial extension")
    func tempPathExtension() {
        let path = URL(fileURLWithPath: "/tmp/model.gguf")
        let temp = ModelDownloader.tempPath(for: path)
        #expect(temp.pathExtension == "partial")
        #expect(temp.deletingPathExtension().lastPathComponent == "model.gguf")
    }

    // MARK: - Init and modelPath

    @Test("modelPath composes cacheDirectory + defaultModelURL filename")
    func modelPathComposition() {
        let cacheDir = URL(fileURLWithPath: "/tmp/test-cache-dir")
        let downloader = ModelDownloader(cacheDirectory: cacheDir)

        let expectedPath = cacheDir.appendingPathComponent(
            ModelDownloader.defaultModelURL.lastPathComponent
        )
        #expect(downloader.modelPath == expectedPath)
        #expect(downloader.modelPath.lastPathComponent == "gemma-4-12b-it-UD-Q4_K_XL.gguf")
    }

    @Test("cacheDirectory is stored as provided")
    func cacheDirectoryStored() {
        let cacheDir = URL(fileURLWithPath: "/Users/test/Library/Application Support/Biscotti/llms")
        let downloader = ModelDownloader(cacheDirectory: cacheDir)
        #expect(downloader.cacheDirectory == cacheDir)
    }

    @Test("Skip-if-present returns existing file without download")
    func skipIfPresent() async throws {
        let tmpDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("llm-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        // Create a non-empty "model" file
        let modelPath = tmpDir.appendingPathComponent("model.gguf")
        try Data(repeating: 0x42, count: 100).write(to: modelPath)

        let downloader = ModelDownloader(cacheDirectory: tmpDir)
        let progressCalled = Mutex(false)
        let result = try await downloader.download(
            from: #require(URL(string: "https://example.com/model.gguf")),
            progress: { _, _ in progressCalled.withLock { $0 = true } }
        )

        #expect(result == modelPath)
        #expect(progressCalled.withLock { $0 } == false) // No download happened
    }
}
