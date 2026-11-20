import Foundation

// MARK: - Where a speaker's name came from

/// What put a name on a speaker.
public enum SpeakerNameSource: String, Codable, Sendable, CaseIterable {
    /// A person picked it in the app (or it carried over from their pick).
    case confirmed
    /// The user's own voice, recognised from the microphone track.
    case microphone
    /// The meeting window highlighted this person while the voice spoke.
    case screen
    /// The voice matched this person's voice in earlier meetings.
    case voice
    /// The AI picked it from the transcript and the invite, with nothing
    /// else backing it up.
    case guess
}

/// How sure the app is of a name.
public enum SpeakerNameConfidence: String, Codable, Sendable, Comparable {
    case low, medium, high

    public var title: String {
        switch self {
        case .low: "Low"
        case .medium: "Medium"
        case .high: "High"
        }
    }

    private var rank: Int {
        switch self {
        case .low: 0
        case .medium: 1
        case .high: 2
        }
    }

    public static func < (lhs: Self, rhs: Self) -> Bool {
        lhs.rank < rhs.rank
    }
}

/// Source, confidence and the evidence behind one speaker's name. Saved
/// with the assignment, so it survives app updates.
public struct SpeakerNameProvenance: Codable, Equatable, Sendable {
    public let source: SpeakerNameSource
    public let confidence: SpeakerNameConfidence
    /// Plain-language evidence, e.g. "Highlighted on screen in 18 of 20 turns".
    public let detail: String?

    public init(source: SpeakerNameSource, confidence: SpeakerNameConfidence, detail: String? = nil) {
        self.source = source
        // A guess is never more than low, whatever the caller says.
        self.confidence = source == .guess ? .low : confidence
        self.detail = detail
    }

    public static let confirmed = SpeakerNameProvenance(
        source: .confirmed, confidence: .high, detail: "Set by hand"
    )
    /// Names saved before provenance existed and not set by hand.
    public static let legacyGuess = SpeakerNameProvenance(
        source: .guess, confidence: .low, detail: "Picked by AI before confidence was recorded"
    )

    /// Text for the badge next to the name. Readable without color.
    public var badgeText: String {
        switch source {
        case .confirmed: "\u{2713} Confirmed"
        case .microphone: "\u{2713} Your mic"
        case .screen: "Screen \u{00B7} \(confidence.title)"
        case .voice: "Voice \u{00B7} \(confidence.title)"
        case .guess: "Guess"
        }
    }

    /// The word added after the name in exports and copies; nil when the
    /// name is solid enough to stand on its own.
    public var qualifier: String? {
        switch source {
        case .confirmed, .microphone:
            nil
        case .guess:
            "guess"
        case .screen, .voice:
            switch confidence {
            case .high: nil
            case .medium: "likely"
            case .low: "unsure"
            }
        }
    }

    /// Names trusted enough to protect from AI changes and to teach the
    /// voice matcher. Everything else stays a suggestion.
    public var isTrusted: Bool {
        switch source {
        case .confirmed, .microphone: true
        case .screen: confidence == .high
        case .voice, .guess: false
        }
    }

    /// "Nora Hale" or "Nora Hale (guess)".
    public func label(_ name: String) -> String {
        qualifier.map { "\(name) (\($0))" } ?? name
    }
}
