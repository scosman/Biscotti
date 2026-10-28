import Foundation
import WhisperKit

/// A Whisper model's files in the app's model cache, for a model the final
/// pass does not download itself, such as the live transcript's.
///
/// The layout is the one the final pass's download leaves:
///
///     <downloadBase>/models/argmaxinc/whisperkit-coreml/<model>/…   (the CoreML model)
///     <downloadBase>/models/openai/whisper-<size>/tokenizer.json    (its tokenizer)
///
/// The worker loads such a model without downloading (`loadLocalWhisperKit`),
/// so both parts must be on disk before a session starts. WhisperKit fetches
/// the tokenizer from the Hub when its local files fail to load, a request
/// that fails offline in the middle of a recording's start; the worker checks
/// that they load first (`tokenizerLoadsLocally`) and reports the model as
/// needing a download otherwise, so the download repairs them instead.
public enum WhisperModelFiles {
    /// The files a tokenizer loads from; WhisperKit's local load needs both.
    static let tokenizerFiles = ["tokenizer.json", "tokenizer_config.json"]
    /// Also read by the local load when present.
    static let optionalTokenizerFiles = ["config.json"]
    /// Records, beside the tokenizer files, the build that last loaded them
    /// and the sizes and modification dates they had then, so later checks in
    /// that build need no tokenizer build (about 1 s in a Debug build;
    /// WhisperKit builds it once more). A new build checks once more: a newer
    /// WhisperKit or tokenizer library may reject files an older one loaded,
    /// and WhisperKit would then fetch them from the Hub.
    static let verifiedMarker = ".biscotti-tokenizer-verified"

    /// The running build: its version, build number and when its executable
    /// was written, so a rebuild with an unchanged version also counts as new.
    /// The app and the transcription worker read their own bundles, so they
    /// count as different builds: after the app downloads the model, the
    /// worker checks the tokenizer once more.
    static let currentBuild = buildIdentity(of: .main)

    /// Whether the model and its tokenizer files are in the model cache.
    /// Reads the disk only; whether the tokenizer loads is checked when the
    /// model loads.
    public static func isPresent(model: String) -> Bool {
        isPresent(model: model, downloadBase: ModelStorage.downloadBase)
    }

    /// Downloads the model folder and its tokenizer into the model cache,
    /// skipping files already there. Never loads or compiles the model.
    ///
    /// - Parameter status: Receives a message for each stage.
    /// - Throws: `TranscriptionError.downloadFailed`, or `.invalidInput` for a
    ///   model name with no known Whisper size.
    public static func download(model: String, status: @escaping @Sendable (String) -> Void) async throws {
        guard let variant = variant(forModel: model) else {
            throw TranscriptionError.invalidInput("No Whisper size in the model name \(model)")
        }
        let base = ModelStorage.downloadBase
        do {
            status("Downloading the live transcript model")
            _ = try await WhisperKit.download(variant: model, downloadBase: base, from: MethodResolver.defaultRepo)
            status("Downloading the live transcript model's tokenizer")
            await removeTokenizerFilesThatDoNotLoad(variant: variant, downloadBase: base)
            _ = try await ModelUtilities.loadTokenizer(for: variant, tokenizerFolder: base)
        } catch {
            throw TranscriptionError.downloadFailed("Live transcript model download failed: \(error.localizedDescription)")
        }
        guard await tokenizerLoadsLocally(variant: variant, downloadBase: base) else {
            throw TranscriptionError.downloadFailed("The live transcript model's tokenizer does not load")
        }
    }

    /// Whether the model's tokenizer loads from the model cache alone, as
    /// WhisperKit's local load does. Never touches the network.
    /// - Parameter build: The build whose earlier check is trusted.
    static func tokenizerLoadsLocally(model: String, downloadBase: URL, build: String = currentBuild) async -> Bool {
        guard let variant = variant(forModel: model) else { return false }
        return await tokenizerLoadsLocally(variant: variant, downloadBase: downloadBase, build: build)
    }

    private static func tokenizerLoadsLocally(variant: ModelVariant, downloadBase: URL, build: String = currentBuild) async -> Bool {
        let folder = tokenizerFolder(for: variant, downloadBase: downloadBase)
        guard let files = tokenizerFilesIdentity(in: folder) else { return false }
        let record = verificationRecord(build: build, files: files)
        let marker = folder.appendingPathComponent(verifiedMarker)
        if (try? String(contentsOf: marker, encoding: .utf8)) == record { return true }
        // The tokenizer library stops the process on some malformed data
        // (a BPE model without merges), so its shape is checked first.
        guard hasWhisperTokenizerShape(in: folder) else { return false }
        do {
            _ = try await AutoTokenizerWrapper.from(modelFolder: folder, hubApi: HubApiWrapper(downloadBase: downloadBase))
        } catch {
            return false
        }
        try? record.write(to: marker, atomically: true, encoding: .utf8)
        return true
    }

    /// The verification record's text: the build, then the files' identity.
    static func verificationRecord(build: String, files: String) -> String {
        "build \(build)\n\(files)"
    }

    /// A bundle's version, build number and its executable's modification time.
    static func buildIdentity(of bundle: Bundle) -> String {
        let info = bundle.infoDictionary ?? [:]
        let version = info["CFBundleShortVersionString"] as? String ?? "-"
        let number = info["CFBundleVersion"] as? String ?? "-"
        let written = bundle.executableURL.flatMap {
            try? $0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
        }
        return "\(version) (\(number)) \(Int((written?.timeIntervalSince1970 ?? 0) * 1000))"
    }

    /// Each tokenizer file's name, size and modification date; nil when a
    /// required file is missing.
    static func tokenizerFilesIdentity(in folder: URL) -> String? {
        var lines: [String] = []
        for name in tokenizerFiles + optionalTokenizerFiles {
            let values = try? folder.appendingPathComponent(name).resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
            guard let values, let size = values.fileSize else {
                if tokenizerFiles.contains(name) { return nil }
                continue
            }
            lines.append("\(name) \(size) \(values.contentModificationDate?.timeIntervalSince1970 ?? 0)")
        }
        return lines.joined(separator: "\n")
    }

    /// Removes the tokenizer's files when they do not load, `config.json`
    /// and the verification record included, so the Hub fetches them again
    /// instead of the cache keeping broken ones.
    static func removeTokenizerFilesThatDoNotLoad(variant: ModelVariant, downloadBase: URL) async {
        guard await !tokenizerLoadsLocally(variant: variant, downloadBase: downloadBase) else { return }
        let folder = tokenizerFolder(for: variant, downloadBase: downloadBase)
        for name in tokenizerFiles + optionalTokenizerFiles + [verifiedMarker] {
            try? FileManager.default.removeItem(at: folder.appendingPathComponent(name))
        }
    }

    /// Both files parse as JSON objects, and the tokenizer is a BPE model
    /// with its vocabulary and merges, as every Whisper tokenizer is.
    static func hasWhisperTokenizerShape(in folder: URL) -> Bool {
        func object(_ name: String) -> [String: Any]? {
            guard let data = try? Data(contentsOf: folder.appendingPathComponent(name)) else { return nil }
            return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        }
        guard object("tokenizer_config.json") != nil,
              let model = object("tokenizer.json")?["model"] as? [String: Any]
        else { return false }
        return model["type"] as? String == "BPE" && model["vocab"] is [String: Any] && model["merges"] is [Any]
    }

    /// Where WhisperKit looks for a variant's tokenizer first:
    /// `<downloadBase>/models/openai/whisper-<size>`.
    static func tokenizerFolder(for variant: ModelVariant, downloadBase: URL) -> URL {
        downloadBase
            .appendingPathComponent("models", isDirectory: true)
            .appendingPathComponent(tokenizerRepo(for: variant), isDirectory: true)
    }

    /// `isPresent(model:)` under an explicit base folder.
    static func isPresent(model: String, downloadBase: URL) -> Bool {
        guard let variant = variant(forModel: model) else { return false }
        let modelFolder = downloadBase
            .appendingPathComponent("models", isDirectory: true)
            .appendingPathComponent(MethodResolver.defaultRepo, isDirectory: true)
            .appendingPathComponent(model, isDirectory: true)
        let tokenizer = tokenizerFolder(for: variant, downloadBase: downloadBase)
        return InProcessTranscriptionEngine.directoryContainsMLModel(modelFolder)
            && tokenizerFiles.allSatisfy { FileManager.default.fileExists(atPath: tokenizer.appendingPathComponent($0).path) }
    }

    /// The Whisper size a model folder name carries, e.g. `.small` for
    /// "openai_whisper-small": the longest size name the part after
    /// "whisper-" starts with.
    static func variant(forModel model: String) -> ModelVariant? {
        guard let range = model.range(of: "whisper-") else { return nil }
        let size = model[range.upperBound...]
        return ModelVariant.allCases
            .filter { size.hasPrefix($0.description) && isSizeBoundary(size.dropFirst($0.description.count).first) }
            .max { $0.description.count < $1.description.count }
    }

    /// The Hugging Face repository WhisperKit takes the tokenizer from.
    static func tokenizerRepo(for variant: ModelVariant) -> String {
        "openai/whisper-\(variant.description)"
    }

    private static func isSizeBoundary(_ next: Character?) -> Bool {
        guard let next else { return true }
        return next == "-" || next == "_"
    }
}
