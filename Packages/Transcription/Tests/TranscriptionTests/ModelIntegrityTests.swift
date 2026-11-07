import Foundation
import Testing
@testable import Transcription

@Suite("ModelIntegrity")
struct ModelIntegrityTests {
    // MARK: - Fixtures

    /// Creates a unique empty temp directory to act as a repo root.
    private func makeRoot() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("ModelIntegrityTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    /// Writes an empty file at `relativePath` under `root`, creating parents.
    private func touch(_ relativePath: String, in root: URL) throws {
        let url = root.appendingPathComponent(relativePath)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        try Data().write(to: url)
    }

    /// Writes every expected file of `component` under `root`.
    private func writeComplete(_ component: ModelComponent, in root: URL) throws {
        for bundle in component.bundleNames {
            for file in ModelIntegrity.requiredBundleFiles {
                try touch("\(component.relativePath)/\(bundle).mlmodelc/\(file)", in: root)
            }
        }
        for file in component.extraFiles {
            try touch("\(component.relativePath)/\(file)", in: root)
        }
    }

    private func exists(_ relativePath: String, in root: URL) -> Bool {
        FileManager.default.fileExists(atPath: root.appendingPathComponent(relativePath).path)
    }

    private var segmenter: ModelComponent {
        ModelIntegrity.speakerKitComponents[0]
    }

    private var embedder: ModelComponent {
        ModelIntegrity.speakerKitComponents[1]
    }

    private var plda: ModelComponent {
        ModelIntegrity.speakerKitComponents[2]
    }

    // MARK: - SpeakerKit components

    @Test("SpeakerKit components match the SDK's default Pyannote models")
    func speakerKitComponentLayout() {
        #expect(segmenter.relativePath.hasPrefix("speaker_segmenter/"))
        #expect(segmenter.bundleNames == ["SpeakerSegmenter"])
        #expect(embedder.relativePath.hasPrefix("speaker_embedder/"))
        #expect(embedder.bundleNames == ["SpeakerEmbedderPreprocessor", "SpeakerEmbedder"])
        #expect(plda.relativePath == "speaker_clusterer/pyannote-v4/W32A32")
        #expect(plda.bundleNames == ["PldaProjector"])
    }

    @Test("complete SpeakerKit tree is complete and nothing is removed")
    func completeSpeakerKitTree() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        for component in ModelIntegrity.speakerKitComponents {
            try writeComplete(component, in: root)
        }

        #expect(ModelIntegrity.isComplete(ModelIntegrity.speakerKitComponents, root: root))
        let removed = try ModelIntegrity.removeIncompleteComponents(
            ModelIntegrity.speakerKitComponents, root: root
        )
        #expect(removed.isEmpty)
        #expect(exists("\(embedder.relativePath)/SpeakerEmbedder.mlmodelc/model.mil", in: root))
    }

    @Test("partial download seen in the field is detected and every broken component is removed")
    func fieldPartialDownload() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        // Layout from a real interrupted download: SpeakerEmbedderPreprocessor
        // missing entirely, the other bundles holding only a few files each.
        try touch("\(segmenter.relativePath)/README.txt", in: root)
        try touch("\(segmenter.relativePath)/SpeakerSegmenter.mlmodelc/metadata.json", in: root)
        try touch("\(embedder.relativePath)/SpeakerEmbedder.mlmodelc/model.mil", in: root)
        try touch("\(embedder.relativePath)/SpeakerEmbedder.mlmodelc/analytics/coremldata.bin", in: root)
        try touch("\(plda.relativePath)/PldaProjector.mlmodelc/weights/weight.bin", in: root)
        try touch(".cache/huggingface/download/README.metadata", in: root)

        #expect(!ModelIntegrity.isComplete(ModelIntegrity.speakerKitComponents, root: root))
        let embedderMissing = ModelIntegrity.missingFiles(in: embedder, root: root)
        #expect(embedderMissing.contains("SpeakerEmbedderPreprocessor.mlmodelc/model.mil"))
        #expect(embedderMissing.contains("SpeakerEmbedder.mlmodelc/weights/weight.bin"))

        let removed = try ModelIntegrity.removeIncompleteComponents(
            ModelIntegrity.speakerKitComponents, root: root
        )
        #expect(removed == ModelIntegrity.speakerKitComponents)
        #expect(!exists(segmenter.relativePath, in: root))
        #expect(!exists(embedder.relativePath, in: root))
        #expect(!exists(plda.relativePath, in: root))
        // Hub metadata outside the component folders is left alone.
        #expect(exists(".cache/huggingface/download/README.metadata", in: root))
    }

    @Test("only the incomplete component is removed; complete ones are untouched")
    func removesOnlyIncompleteComponent() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        try writeComplete(segmenter, in: root)
        try writeComplete(plda, in: root)
        try writeComplete(embedder, in: root)
        try FileManager.default.removeItem(
            at: root.appendingPathComponent("\(embedder.relativePath)/SpeakerEmbedder.mlmodelc/weights/weight.bin")
        )

        #expect(ModelIntegrity.missingFiles(in: embedder, root: root) == ["SpeakerEmbedder.mlmodelc/weights/weight.bin"])
        let removed = try ModelIntegrity.removeIncompleteComponents(
            ModelIntegrity.speakerKitComponents, root: root
        )
        #expect(removed == [embedder])
        #expect(!exists(embedder.relativePath, in: root))
        #expect(exists("\(segmenter.relativePath)/SpeakerSegmenter.mlmodelc/model.mil", in: root))
        #expect(exists("\(plda.relativePath)/PldaProjector.mlmodelc/model.mil", in: root))
    }

    @Test("a missing bundle makes the component incomplete")
    func missingBundle() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        try writeComplete(embedder, in: root)
        try FileManager.default.removeItem(
            at: root.appendingPathComponent("\(embedder.relativePath)/SpeakerEmbedderPreprocessor.mlmodelc")
        )

        let missing = ModelIntegrity.missingFiles(in: embedder, root: root)
        #expect(missing.count == ModelIntegrity.requiredBundleFiles.count)
        #expect(missing.allSatisfy { $0.hasPrefix("SpeakerEmbedderPreprocessor.mlmodelc/") })
    }

    @Test("a missing root is incomplete and repair does not throw")
    func missingRoot() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("ModelIntegrityTests-missing-\(UUID().uuidString)", isDirectory: true)

        #expect(!ModelIntegrity.isComplete(ModelIntegrity.speakerKitComponents, root: root))
        let removed = try ModelIntegrity.removeIncompleteComponents(
            ModelIntegrity.speakerKitComponents, root: root
        )
        #expect(removed == ModelIntegrity.speakerKitComponents)
        #expect(!FileManager.default.fileExists(atPath: root.path))
    }

    @Test("a folder that cannot be deleted throws downloadFailed")
    func undeletableFolderThrowsDownloadFailed() throws {
        let root = try makeRoot()
        try touch("\(segmenter.relativePath)/stray.bin", in: root)
        // Deleting a folder needs write access to its parent.
        let parent = root.appendingPathComponent(segmenter.relativePath).deletingLastPathComponent()
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: parent.path)
        defer {
            try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: parent.path)
            try? FileManager.default.removeItem(at: root)
        }

        let error = #expect(throws: TranscriptionError.self) {
            try ModelIntegrity.removeIncompleteComponents([segmenter], root: root)
        }
        guard case let .downloadFailed(detail) = error else {
            Issue.record("expected downloadFailed, got \(String(describing: error))")
            return
        }
        #expect(detail.contains(segmenter.relativePath))
    }

    // MARK: - Post-download check

    @Test("requireComplete accepts a complete tree")
    func requireCompleteAcceptsCompleteTree() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        for component in ModelIntegrity.speakerKitComponents {
            try writeComplete(component, in: root)
        }

        try ModelIntegrity.requireComplete(ModelIntegrity.speakerKitComponents, root: root, label: "SpeakerKit")
    }

    @Test("requireComplete throws downloadFailed naming the missing file")
    func requireCompleteNamesMissingFile() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        try writeComplete(segmenter, in: root)
        let missing = "\(segmenter.relativePath)/SpeakerSegmenter.mlmodelc/model.mil"
        try FileManager.default.removeItem(at: root.appendingPathComponent(missing))

        let error = #expect(throws: TranscriptionError.self) {
            try ModelIntegrity.requireComplete([segmenter], root: root, label: "SpeakerKit")
        }
        guard case let .downloadFailed(detail) = error else {
            Issue.record("expected downloadFailed, got \(String(describing: error))")
            return
        }
        #expect(detail.hasPrefix("SpeakerKit: "))
        #expect(detail.contains(missing))
    }

    // MARK: - WhisperKit component

    @Test("complete WhisperKit model folder is complete")
    func completeWhisperKitModel() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let component = ModelIntegrity.whisperKitComponent(modelName: "openai_whisper-test")
        try writeComplete(component, in: root)

        #expect(ModelIntegrity.isComplete([component], root: root))
    }

    @Test("WhisperKit model folder without config.json is incomplete and removed")
    func whisperKitMissingConfig() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let component = ModelIntegrity.whisperKitComponent(modelName: "openai_whisper-test")
        try writeComplete(component, in: root)
        try FileManager.default.removeItem(
            at: root.appendingPathComponent("openai_whisper-test/config.json")
        )

        #expect(ModelIntegrity.missingFiles(in: component, root: root) == ["config.json"])
        let removed = try ModelIntegrity.removeIncompleteComponents([component], root: root)
        #expect(removed == [component])
        #expect(!exists("openai_whisper-test", in: root))
    }
}
