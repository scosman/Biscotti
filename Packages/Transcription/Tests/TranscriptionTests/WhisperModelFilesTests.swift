import Foundation
import Testing
import WhisperKit
@testable import Transcription

@Suite("WhisperModelFiles")
struct WhisperModelFilesTests {
    private func makeBase() throws -> URL {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("WhisperModelFilesTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return base
    }

    private func create(_ path: String, in base: URL, directory: Bool) throws {
        let url = base.appendingPathComponent(path)
        if directory {
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        } else {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data("{}".utf8).write(to: url)
        }
    }

    @Test("A model is present only with its compiled model and its tokenizer")
    func presentNeedsModelAndTokenizer() throws {
        let base = try makeBase()
        defer { try? FileManager.default.removeItem(at: base) }
        let model = "openai_whisper-small"
        #expect(!WhisperModelFiles.isPresent(model: model, downloadBase: base))

        try create("models/argmaxinc/whisperkit-coreml/\(model)/AudioEncoder.mlmodelc", in: base, directory: true)
        #expect(!WhisperModelFiles.isPresent(model: model, downloadBase: base), "the tokenizer is missing")

        try create("models/openai/whisper-small/tokenizer.json", in: base, directory: false)
        #expect(!WhisperModelFiles.isPresent(model: model, downloadBase: base), "WhisperKit's local load also needs tokenizer_config.json")

        try create("models/openai/whisper-small/tokenizer_config.json", in: base, directory: false)
        #expect(WhisperModelFiles.isPresent(model: model, downloadBase: base))
        #expect(!WhisperModelFiles.isPresent(model: "openai_whisper-base", downloadBase: base))
    }

    /// Writes the small tokenizer's two files, valid or not.
    private func writeTokenizer(config: String?, data: String?, in base: URL) throws {
        let folder = base.appendingPathComponent("models/openai/whisper-small", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        if let config { try Data(config.utf8).write(to: folder.appendingPathComponent("tokenizer_config.json")) }
        if let data { try Data(data.utf8).write(to: folder.appendingPathComponent("tokenizer.json")) }
    }

    private static let validConfig = #"{"tokenizer_class": "WhisperTokenizer"}"#
    private static let validData = #"{"model": {"type": "BPE", "vocab": {"a": 0, "b": 1, "ab": 2}, "merges": ["a b"]}}"#

    @Test("A tokenizer loads from the cache alone when both files are there and valid")
    func validTokenizerLoadsLocally() async throws {
        let base = try makeBase()
        defer { try? FileManager.default.removeItem(at: base) }
        try writeTokenizer(config: Self.validConfig, data: Self.validData, in: base)

        #expect(await WhisperModelFiles.tokenizerLoadsLocally(model: "openai_whisper-small", downloadBase: base))
    }

    @Test("An incomplete or corrupt tokenizer does not load from the cache, and nothing is fetched", .timeLimit(.minutes(1)))
    func incompleteOrCorruptTokenizerDoesNotLoad() async throws {
        let cases: [(config: String?, data: String?)] = [
            (nil, Self.validData),
            (Self.validConfig, nil),
            (Self.validConfig, "not json"),
            (Self.validConfig, "{}"),
            ("not json", Self.validData),
            // Valid JSON the tokenizer library would stop the process on.
            (Self.validConfig, #"{"model": {"type": "BPE", "vocab": {"a": 0}}}"#)
        ]
        for files in cases {
            let base = try makeBase()
            defer { try? FileManager.default.removeItem(at: base) }
            try writeTokenizer(config: files.config, data: files.data, in: base)

            #expect(await !WhisperModelFiles.tokenizerLoadsLocally(model: "openai_whisper-small", downloadBase: base))
            // Only what the test wrote: no fetch filled the cache, and nothing was recorded as verified.
            let folder = base.appendingPathComponent("models/openai/whisper-small")
            let written = [files.config.map { _ in "tokenizer_config.json" }, files.data.map { _ in "tokenizer.json" }].compactMap(\.self)
            #expect(try FileManager.default.contentsOfDirectory(atPath: folder.path).sorted() == written.sorted())
        }
    }

    @Test("A tokenizer that loaded is recorded, so it is not built again until its files change")
    func loadedTokenizerIsRecordedUntilItsFilesChange() async throws {
        let base = try makeBase()
        defer { try? FileManager.default.removeItem(at: base) }
        try writeTokenizer(config: Self.validConfig, data: Self.validData, in: base)
        let folder = base.appendingPathComponent("models/openai/whisper-small")
        let marker = folder.appendingPathComponent(WhisperModelFiles.verifiedMarker)

        #expect(await WhisperModelFiles.tokenizerLoadsLocally(model: "openai_whisper-small", downloadBase: base))
        #expect(FileManager.default.fileExists(atPath: marker.path))

        // The record matches only the files it was made for.
        try writeTokenizer(config: nil, data: "not json at all", in: base)
        #expect(await !WhisperModelFiles.tokenizerLoadsLocally(model: "openai_whisper-small", downloadBase: base))
    }

    @Test("A record another build wrote is not trusted, so each new build checks the tokenizer once")
    func recordFromAnotherBuildIsCheckedAgain() async throws {
        let base = try makeBase()
        defer { try? FileManager.default.removeItem(at: base) }
        let model = "openai_whisper-small"
        let folder = base.appendingPathComponent("models/openai/whisper-small")
        let marker = folder.appendingPathComponent(WhisperModelFiles.verifiedMarker)
        try writeTokenizer(config: Self.validConfig, data: Self.validData, in: base)
        #expect(await WhisperModelFiles.tokenizerLoadsLocally(model: model, downloadBase: base, build: "1"))
        #expect(try String(contentsOf: marker, encoding: .utf8).hasPrefix("build 1\n"))

        // Files an older build recorded as loading, which this build's check rejects.
        try writeTokenizer(config: Self.validConfig, data: "{}", in: base)
        let files = try #require(WhisperModelFiles.tokenizerFilesIdentity(in: folder))
        try WhisperModelFiles.verificationRecord(build: "1", files: files).write(to: marker, atomically: true, encoding: .utf8)
        #expect(await WhisperModelFiles.tokenizerLoadsLocally(model: model, downloadBase: base, build: "1"), "the build that wrote the record trusts it")
        #expect(await !WhisperModelFiles.tokenizerLoadsLocally(model: model, downloadBase: base, build: "2"), "a new build checks again")
    }

    @Test("The build identity names the version, the build number and when the executable was written")
    func buildIdentityNamesVersionAndExecutable() {
        let identity = WhisperModelFiles.buildIdentity(of: .main)
        #expect(identity == WhisperModelFiles.currentBuild)
        #expect(!identity.hasSuffix(" 0"), "the test runner's executable has a modification date")
    }

    @Test("Repair removes tokenizer files that do not load, config.json and the record included, and keeps ones that load")
    func repairRemovesOnlyBrokenTokenizerFiles() async throws {
        let small = try #require(WhisperModelFiles.variant(forModel: "openai_whisper-small"))
        let broken = try makeBase()
        defer { try? FileManager.default.removeItem(at: broken) }
        try writeTokenizer(config: Self.validConfig, data: Self.validData, in: broken)
        let folder = broken.appendingPathComponent("models/openai/whisper-small")
        try Data("not json".utf8).write(to: folder.appendingPathComponent("config.json"))
        try Data("stale".utf8).write(to: folder.appendingPathComponent(WhisperModelFiles.verifiedMarker))

        await WhisperModelFiles.removeTokenizerFilesThatDoNotLoad(variant: small, downloadBase: broken)
        #expect(try FileManager.default.contentsOfDirectory(atPath: folder.path).isEmpty)

        let healthy = try makeBase()
        defer { try? FileManager.default.removeItem(at: healthy) }
        try writeTokenizer(config: Self.validConfig, data: Self.validData, in: healthy)
        await WhisperModelFiles.removeTokenizerFilesThatDoNotLoad(variant: small, downloadBase: healthy)
        let kept = try FileManager.default.contentsOfDirectory(atPath: healthy.appendingPathComponent("models/openai/whisper-small").path)
        #expect(Set(kept).isSuperset(of: ["tokenizer.json", "tokenizer_config.json"]))
    }

    @Test("The never-downloading loader reports a cache with a broken tokenizer as needing a download, before WhisperKit can fetch one")
    func brokenTokenizerNeedsDownload() async throws {
        let base = try makeBase()
        defer { try? FileManager.default.removeItem(at: base) }
        let model = "openai_whisper-small"
        try create("models/argmaxinc/whisperkit-coreml/\(model)/AudioEncoder.mlmodelc", in: base, directory: true)
        try writeTokenizer(config: Self.validConfig, data: "not json", in: base)
        #expect(WhisperModelFiles.isPresent(model: model, downloadBase: base), "the files are there")

        await #expect(throws: TranscriptionError.needsDownload) {
            _ = try await InProcessTranscriptionEngine.loadLocalWhisperKit(model: model, downloadBase: base)
        }
    }

    @Test("A live session on the final pass's model loads it only from the cache: a missing model needs a download, before WhisperKit can fetch one")
    func sharedFinalPassModelNeedsDownloadInsteadOfDownloading() async throws {
        let base = try makeBase()
        defer { try? FileManager.default.removeItem(at: base) }
        let engine = InProcessTranscriptionEngine()
        await #expect(throws: TranscriptionError.needsDownload) {
            _ = try await engine.loadedWhisperKit(downloadBase: base)
        }

        // The compiled model alone is not enough: its tokenizer must load from the cache too.
        try create("models/\(MethodResolver.defaultRepo)/\(engine.whisperModelName)/AudioEncoder.mlmodelc", in: base, directory: true)
        await #expect(throws: TranscriptionError.needsDownload) {
            _ = try await engine.loadedWhisperKit(downloadBase: base)
        }
        #expect(await engine.status() == .needsDownload, "nothing started loading")
    }

    @Test("A model the download step left unloaded is checked in the cache too, before loading it could fetch a tokenizer")
    func sharedUnloadedModelNeedsDownloadInsteadOfLoading() async throws {
        let base = try makeBase()
        defer { try? FileManager.default.removeItem(at: base) }
        let model = MethodResolver.resolve(.current).sttModel
        let folder = base.appendingPathComponent("models/\(MethodResolver.defaultRepo)/\(model)", isDirectory: true)
        try create("models/\(MethodResolver.defaultRepo)/\(model)/AudioEncoder.mlmodelc", in: base, directory: true)
        // What `ensureModelsDownloaded` leaves: an instance with its folder set and nothing loaded.
        let downloaded = try await WhisperKit(WhisperKitConfig(
            model: model, downloadBase: base, modelFolder: folder.path, verbose: false, load: false, download: false
        ))
        let engine = InProcessTranscriptionEngine(diskSpaceChecker: SystemDiskSpaceChecker(), whisperKit: downloaded)

        // `loadModels()` would fail on the empty model folder with another error.
        await #expect(throws: TranscriptionError.needsDownload) {
            _ = try await engine.loadedWhisperKit(downloadBase: base)
        }
    }

    @Test("The Whisper size comes from the model folder name")
    func variantFromFolderName() throws {
        #expect(WhisperModelFiles.variant(forModel: "openai_whisper-small")?.description == "small")
        #expect(WhisperModelFiles.variant(forModel: "openai_whisper-small.en")?.description == "small.en")
        #expect(WhisperModelFiles.variant(forModel: "openai_whisper-large-v3-v20240930_626MB")?.description == "large-v3")
        #expect(WhisperModelFiles.variant(forModel: "openai_whisper-large-v2")?.description == "large-v2")
        #expect(WhisperModelFiles.variant(forModel: "distil-something") == nil)
        let small = try #require(WhisperModelFiles.variant(forModel: "openai_whisper-small"))
        #expect(WhisperModelFiles.tokenizerRepo(for: small) == "openai/whisper-small")
    }
}
