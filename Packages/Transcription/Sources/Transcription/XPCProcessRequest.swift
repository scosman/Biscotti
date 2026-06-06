import Foundation

/// The request payload for `TranscriberServiceProtocol.processAudio(requestData:reply:)`.
///
/// Bundles the audio paths and custom vocabulary into a single
/// JSON-encoded `Data` blob for transport across the XPC boundary. This keeps
/// the `@objc` protocol's parameter count within lint limits while remaining
/// fully `Codable`.
struct XPCProcessRequest: Codable {
    let micPath: String
    let systemPath: String
    let customVocabulary: [String]
}
