import Foundation
import os.log
import SpeakerKit
import WhisperKit

/// One downloadable model folder and the files it must contain to be usable.
///
/// A component maps to one Hub download pattern (e.g. the SpeakerKit
/// segmenter's `speaker_segmenter/pyannote-v3/W8A16/*`), so removing an
/// incomplete component's folder makes the SDK re-download exactly that part.
struct ModelComponent: Equatable {
    /// Folder path relative to the repo root (e.g. `speaker_segmenter/pyannote-v3/W8A16`).
    let relativePath: String

    /// `.mlmodelc` bundle names (without extension) expected in the folder.
    let bundleNames: [String]

    /// Other files expected in the folder (e.g. `config.json`).
    let extraFiles: [String]
}

/// Detects and repairs partially downloaded models.
///
/// The ArgMax SDK's cache check (`ModelDownloader.resolveRepo`) only checks that
/// each model folder is non-empty and that the files *present* are valid. It never
/// compares against the repo's file list, so an interrupted download is accepted
/// as a valid cache forever and CoreML fails at load time
/// ([argmax-oss-swift#491](https://github.com/argmaxinc/argmax-oss-swift/issues/491)).
/// We check the expected files ourselves and delete an incomplete component's
/// folder, so the SDK's next download fetches it again.
///
/// Corrupt or truncated files are already caught by the SDK (it hashes the files
/// that are present), so this only needs to detect *missing* files.
enum ModelIntegrity {
    private static let log = Logger(
        subsystem: "net.scosman.biscotti",
        category: "ModelIntegrity"
    )

    /// Files every compiled CoreML bundle in the ArgMax repos contains.
    static let requiredBundleFiles = [
        "coremldata.bin",
        "model.mil",
        "metadata.json",
        "weights/weight.bin"
    ]

    // MARK: - Repo roots

    /// Root of the SpeakerKit repo in the shared cache.
    static var speakerKitRoot: URL {
        ModelStorage.modelsDirectory
            .appendingPathComponent("argmaxinc/speakerkit-coreml", isDirectory: true)
    }

    /// Root of a WhisperKit repo (e.g. `argmaxinc/whisperkit-coreml`) in the shared cache.
    static func whisperKitRoot(repo: String) -> URL {
        ModelStorage.modelsDirectory.appendingPathComponent(repo, isDirectory: true)
    }

    // MARK: - Components

    /// The SpeakerKit (Pyannote) components, using the SDK's default model
    /// infos (the same ones `SpeakerKitConfigFactory` configs resolve to).
    /// Bundle names match what `PyannoteModelManager.load` loads.
    static let speakerKitComponents: [ModelComponent] = [
        ModelComponent(
            relativePath: ModelInfo.segmenter().description,
            bundleNames: ["SpeakerSegmenter"],
            extraFiles: []
        ),
        ModelComponent(
            relativePath: ModelInfo.embedder().description,
            bundleNames: ["SpeakerEmbedderPreprocessor", "SpeakerEmbedder"],
            extraFiles: []
        ),
        ModelComponent(
            relativePath: ModelInfo.plda().description,
            bundleNames: ["PldaProjector"],
            extraFiles: []
        )
    ]

    /// The WhisperKit component for `modelName` (e.g. `openai_whisper-large-v3-v20240930_626MB`).
    static func whisperKitComponent(modelName: String) -> ModelComponent {
        ModelComponent(
            relativePath: modelName,
            bundleNames: ["MelSpectrogram", "AudioEncoder", "TextDecoder"],
            extraFiles: ["config.json", "generation_config.json"]
        )
    }

    // MARK: - Checks

    /// Expected files of `component` that are missing under `root`, as
    /// component-relative paths. Empty means the component is complete.
    static func missingFiles(in component: ModelComponent, root: URL) -> [String] {
        let fileManager = FileManager.default
        let componentDir = root.appendingPathComponent(component.relativePath, isDirectory: true)
        let bundleFiles = component.bundleNames.flatMap { bundle in
            requiredBundleFiles.map { "\(bundle).mlmodelc/\($0)" }
        }
        return (bundleFiles + component.extraFiles).filter { relative in
            !fileManager.fileExists(atPath: componentDir.appendingPathComponent(relative).path)
        }
    }

    /// Whether every component has all its expected files under `root`.
    static func isComplete(_ components: [ModelComponent], root: URL) -> Bool {
        components.allSatisfy { missingFiles(in: $0, root: root).isEmpty }
    }

    /// Checks a download that the SDK reported as successful. The SDK can
    /// return a partial cache without an error, e.g. when the download is
    /// cancelled (fixed upstream in argmax-oss-swift v1.1.1, #534).
    ///
    /// - Throws: ``TranscriptionError/downloadFailed(_:)`` naming the missing
    ///   files, prefixed with `label`, if any component is incomplete.
    static func requireComplete(_ components: [ModelComponent], root: URL, label: String) throws {
        let missing = components.flatMap { component in
            missingFiles(in: component, root: root).map { "\(component.relativePath)/\($0)" }
        }
        guard missing.isEmpty else {
            throw TranscriptionError.downloadFailed(
                "\(label): incomplete download, missing \(missing.joined(separator: ", "))"
            )
        }
    }

    // MARK: - Repair

    /// Deletes the folder of each component that is missing files, so the SDK
    /// re-downloads it. Only touches folders under `root`.
    ///
    /// - Returns: The components that were incomplete (whether or not a folder
    ///   existed to delete). Empty means everything was already complete.
    /// - Throws: ``TranscriptionError/downloadFailed(_:)`` if a folder cannot
    ///   be deleted.
    @discardableResult
    static func removeIncompleteComponents(
        _ components: [ModelComponent],
        root: URL
    ) throws -> [ModelComponent] {
        let fileManager = FileManager.default
        var incomplete: [ModelComponent] = []
        for component in components {
            let missing = missingFiles(in: component, root: root)
            guard !missing.isEmpty else { continue }
            incomplete.append(component)

            let componentDir = root.appendingPathComponent(component.relativePath, isDirectory: true)
            guard fileManager.fileExists(atPath: componentDir.path) else { continue }
            log.notice(
                "Removing incomplete model \(component.relativePath, privacy: .public) (missing: \(missing.joined(separator: ", "), privacy: .public))"
            )
            do {
                try fileManager.removeItem(at: componentDir)
            } catch {
                throw TranscriptionError.downloadFailed(
                    "Could not remove incomplete model \(component.relativePath): \(error.localizedDescription)"
                )
            }
        }
        return incomplete
    }
}
