import Foundation

/// The request payload for `TranscriberServiceProtocol.processAudio(requestData:reply:)`.
///
/// Bundles the audio paths, custom vocabulary and spoken language into a single
/// JSON-encoded `Data` blob for transport across the XPC boundary. This keeps
/// the `@objc` protocol's parameter count within lint limits while remaining
/// fully `Codable`.
public struct XPCProcessRequest: Codable {
    public let micPath: String
    public let systemPath: String
    public let customVocabulary: [String]
    public let language: TranscriptionLanguage

    public init(
        micPath: String,
        systemPath: String,
        customVocabulary: [String],
        language: TranscriptionLanguage
    ) {
        self.micPath = micPath
        self.systemPath = systemPath
        self.customVocabulary = customVocabulary
        self.language = language
    }
}
