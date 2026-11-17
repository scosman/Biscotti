import Foundation

/// Parsed response from the OpenRouter audio transcription API.
///
/// All fields are optional because different models return different subsets.
/// The raw body is always saved separately, so a parse change never needs a re-upload.
public struct ReferenceResponse: Decodable, Sendable, Equatable {
    public var text: String?
    public var language: String?
    public var duration: Double?
    public var segments: [Seg]?
    public var words: [Word]?
    public var usage: Usage?
    public var model: String?
    public var provider: String?

    public struct Seg: Decodable, Sendable, Equatable {
        public var start: Double
        public var end: Double
        public var text: String
        public var speaker: String?
    }

    public struct Word: Decodable, Sendable, Equatable {
        public var word: String
        public var start: Double
        public var end: Double
        public var confidence: Double?
        public var speaker: String?
    }

    public struct Usage: Decodable, Sendable, Equatable {
        public var seconds: Double?
        public var cost: Double?
    }
}
