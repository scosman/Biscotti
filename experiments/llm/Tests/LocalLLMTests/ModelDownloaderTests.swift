import Foundation
import Synchronization
import Testing

@testable import LocalLLM

@Suite("ModelDownloader")
struct ModelDownloaderTests {
    @Test("deriveFilename extracts last path component")
    func deriveFilename() {
        let url = URL(
            string:
                "https://huggingface.co/unsloth/gemma-4-12b-it-GGUF/resolve/main/gemma-4-12b-it-UD-Q4_K_XL.gguf"
        )!
        #expect(ModelDownloader.deriveFilename(from: url) == "gemma-4-12b-it-UD-Q4_K_XL.gguf")
    }

    @Test("defaultModelURL is well-formed")
    func defaultURL() {
        let url = ModelDownloader.defaultModelURL
        #expect(url.scheme == "https")
        #expect(url.host == "huggingface.co")
        #expect(url.lastPathComponent == "gemma-4-12b-it-UD-Q4_K_XL.gguf")
    }

    @Test("resolveDestination with file path returns as-is")
    func resolveDestinationFile() throws {
        let tmpDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("llm-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        let filePath = tmpDir.appendingPathComponent("model.gguf")
        let source = URL(string: "https://example.com/remote.gguf")!
        let result = ModelDownloader.resolveDestination(source: source, destination: filePath)
        #expect(result.lastPathComponent == "model.gguf")
    }

    @Test("resolveDestination with directory appends source filename")
    func resolveDestinationDirectory() throws {
        let tmpDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("llm-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        let source = URL(string: "https://example.com/mymodel.gguf")!
        let result = ModelDownloader.resolveDestination(source: source, destination: tmpDir)
        #expect(result.lastPathComponent == "mymodel.gguf")
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

    @Test("tempPath adds .partial extension")
    func tempPathExtension() {
        let path = URL(fileURLWithPath: "/tmp/model.gguf")
        let temp = ModelDownloader.tempPath(for: path)
        #expect(temp.pathExtension == "partial")
        #expect(temp.deletingPathExtension().lastPathComponent == "model.gguf")
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

        let downloader = ModelDownloader()
        let progressCalled = Mutex(false)
        let result = try await downloader.download(
            from: URL(string: "https://example.com/model.gguf")!,
            to: modelPath,
            progress: { _, _ in progressCalled.withLock { $0 = true } }
        )

        #expect(result == modelPath)
        #expect(progressCalled.withLock { $0 } == false) // No download happened
    }
}
