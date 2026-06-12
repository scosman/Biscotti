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

    @Test("resolveDestination with file path (.gguf) returns as-is")
    func resolveDestinationFile() throws {
        let tmpDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("llm-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        // filePath does NOT exist on disk — this validates the non-existent-path +
        // matching-extension branch (dest ext `.gguf` == source ext `.gguf` → file).
        let filePath = tmpDir.appendingPathComponent("model.gguf")
        let source = URL(string: "https://example.com/remote.gguf")!
        let result = ModelDownloader.resolveDestination(source: source, destination: filePath)
        #expect(result.lastPathComponent == "model.gguf")
        // The file path is returned unchanged (not double-appended)
        #expect(result == filePath)
    }

    @Test("resolveDestination with existing directory appends source filename")
    func resolveDestinationExistingDirectory() throws {
        let tmpDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("llm-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        let source = URL(string: "https://example.com/mymodel.gguf")!
        let result = ModelDownloader.resolveDestination(source: source, destination: tmpDir)
        #expect(result.lastPathComponent == "mymodel.gguf")
        #expect(result == tmpDir.appendingPathComponent("mymodel.gguf"))
    }

    @Test(
        "resolveDestination with non-existent directory (no trailing slash) appends source filename"
    )
    func resolveDestinationNonExistentDirectory() {
        // Regression: a cache directory path like ~/Library/Caches/net.scosman.biscotti.localllm
        // that does not exist yet and has no trailing slash must still be treated as a directory
        // (its last component has no extension), NOT as a file path.
        let nonExistent = FileManager.default.temporaryDirectory
            .appendingPathComponent("llm-test-\(UUID().uuidString)")
            .appendingPathComponent("net.scosman.biscotti.localllm")
        // Verify it truly does not exist
        #expect(!FileManager.default.fileExists(atPath: nonExistent.path))

        let source = URL(string: "https://example.com/gemma-4-12b.gguf")!
        let result = ModelDownloader.resolveDestination(source: source, destination: nonExistent)
        #expect(result.lastPathComponent == "gemma-4-12b.gguf")
        #expect(result == nonExistent.appendingPathComponent("gemma-4-12b.gguf"))
    }

    @Test("resolveDestination with trailing-slash directory appends source filename")
    func resolveDestinationTrailingSlash() {
        let dest = URL(fileURLWithPath: "/tmp/some-cache-dir/")
        let source = URL(string: "https://example.com/model.gguf")!
        let result = ModelDownloader.resolveDestination(source: source, destination: dest)
        #expect(result.lastPathComponent == "model.gguf")
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

    // MARK: - Default model path agreement (run + download single source of truth)

    @Test("defaultModelDirectory is under ~/Library/Caches")
    func defaultModelDirectory() {
        let dir = ModelDownloader.defaultModelDirectory
        #expect(dir.path.hasSuffix("Library/Caches/net.scosman.biscotti.localllm"))
    }

    /// Exercises the real `ModelDownloader.defaultModelPath` static and verifies it equals
    /// `defaultModelDirectory` joined with `defaultModelURL.lastPathComponent`. Both CLI commands
    /// (`run` and `download`) use these same library statics for their defaults.
    @Test("defaultModelPath equals defaultModelDirectory + defaultModelURL filename")
    func defaultModelPathAgreement() {
        let actualPath = ModelDownloader.defaultModelPath

        // Independently derive the expected value from the two constituent statics
        let expectedPath = ModelDownloader.defaultModelDirectory
            .appendingPathComponent(ModelDownloader.defaultModelURL.lastPathComponent)

        #expect(actualPath == expectedPath)

        // Lock the known filename so a URL change is caught
        #expect(actualPath.lastPathComponent == "gemma-4-12b-it-UD-Q4_K_XL.gguf")

        // Lock the expected full suffix
        #expect(actualPath.path.hasSuffix(
            "Library/Caches/net.scosman.biscotti.localllm/gemma-4-12b-it-UD-Q4_K_XL.gguf"
        ))
    }

    /// Regression: `DownloadCommand`'s default --dest is `defaultModelPath` (a .gguf file path).
    /// `resolveDestination` must return it unchanged — so `download` writes to exactly the path
    /// that `run` reads from. Also verify that passing `defaultModelDirectory` (the old default)
    /// through `resolveDestination` ALSO yields `defaultModelPath`, so either form works.
    @Test("resolveDestination with default paths yields defaultModelPath")
    func resolveDestinationDefaultPaths() {
        let source = ModelDownloader.defaultModelURL

        // Case 1: default dest is the full file path (current DownloadCommand default)
        let fromFilePath = ModelDownloader.resolveDestination(
            source: source, destination: ModelDownloader.defaultModelPath
        )
        #expect(fromFilePath == ModelDownloader.defaultModelPath)

        // Case 2: default dest is the directory (the old DownloadCommand default) — must also
        // resolve to the same file because the directory's last component has no extension.
        let fromDirPath = ModelDownloader.resolveDestination(
            source: source, destination: ModelDownloader.defaultModelDirectory
        )
        #expect(fromDirPath == ModelDownloader.defaultModelPath)
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
