import Foundation

/// Resolves where on-device models are cached.
///
/// The ArgMax SDK (via its bundled HuggingFace Hub layer) otherwise defaults to
/// `~/Documents/huggingface`, which dumps a multi-GB cache into the user's
/// Documents folder — the wrong place for regenerable app-support data (it
/// clutters Documents and can get swept into iCloud/Desktop&Documents sync).
///
/// We override `downloadBase` to live under Application Support instead. The Hub
/// layer appends `models/<repo>` beneath this base, so models ultimately land at:
///
///     ~/Library/Application Support/Biscotti/models/argmaxinc/whisperkit-coreml/…
///     ~/Library/Application Support/Biscotti/models/argmaxinc/speakerkit-coreml/…
///
/// The same literal subdirectory name is used regardless of which process
/// (the app or the `BiscottiTranscriber` XPC service) creates it, so both share
/// one cache.
enum ModelStorage {
    /// Base directory handed to WhisperKit / SpeakerKit as their `downloadBase`.
    static let downloadBase: URL = {
        let appSupport = FileManager.default.urls(
            for: .applicationSupportDirectory, in: .userDomainMask
        ).first ?? URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent("Library/Application Support", isDirectory: true)
        return appSupport.appendingPathComponent("Biscotti", isDirectory: true)
    }()

    /// The directory the Hub layer fills with downloaded models
    /// (`downloadBase/models/<repo>/…`). This is the whole on-disk model cache.
    ///
    /// The ArgMax Hub client creates this tree itself (`createDirectory` with
    /// `withIntermediateDirectories: true`) on every download, so there is no
    /// need to pre-create `downloadBase`.
    static var modelsDirectory: URL {
        downloadBase.appendingPathComponent("models", isDirectory: true)
    }

    /// Delete all downloaded models from disk. No-op if nothing is cached.
    /// Only removes the model cache (`models/`), leaving any sibling app data
    /// under the base directory untouched.
    static func clearCache() throws {
        let fileManager = FileManager.default
        guard fileManager.fileExists(atPath: modelsDirectory.path) else { return }
        try fileManager.removeItem(at: modelsDirectory)
    }
}
