import Foundation

/// The request payload for `TranscriberServiceProtocol.processAudio(requestData:reply:)`.
///
/// Bundles the audio paths, custom vocabulary, and engine config into a single
/// JSON-encoded `Data` blob for transport across the XPC boundary. This keeps
/// the `@objc` protocol's parameter count within lint limits while remaining
/// fully `Codable`.
public struct XPCProcessRequest: Codable {
    public let micPath: String
    public let systemPath: String
    public let customVocabulary: [String]

    /// Per-call config (engine + locale). Absent in requests from older clients;
    /// the service defaults to `.whisper()`.
    public let config: TranscriptionConfig?

    public init(
        micPath: String,
        systemPath: String,
        customVocabulary: [String],
        config: TranscriptionConfig? = nil
    ) {
        self.micPath = micPath
        self.systemPath = systemPath
        self.customVocabulary = customVocabulary
        self.config = config
    }
}

/// The request payload for `TranscriberServiceProtocol.ensureModelsDownloaded(requestData:reply:)`.
///
/// Carries the set of components to download.
public struct XPCDownloadRequest: Codable {
    public let components: [ModelComponent]

    public init(components: Set<ModelComponent>) {
        self.components = Array(components).sorted { $0.rawValue < $1.rawValue }
    }

    /// Decode as a set. Empty/invalid → `.all`.
    public var componentSet: Set<ModelComponent> {
        let set = Set(components)
        return set.isEmpty ? .all : set
    }
}
