import DataStore

/// Distance thresholds for one voiceprint kind (raw or PLDA).
public struct KindThresholds: Sendable, Equatable {
    /// Maximum distance to consider a voiceprint a potential match.
    public var acceptRadius: Float
    /// Distance at or below which a match can qualify as high confidence.
    public var highDistance: Float
    /// Distance at or below which a match can qualify as medium confidence.
    public var mediumDistance: Float

    public init(acceptRadius: Float, highDistance: Float, mediumDistance: Float) {
        self.acceptRadius = acceptRadius
        self.highDistance = highDistance
        self.mediumDistance = mediumDistance
    }
}

/// All tuneable constants for voiceprint matching. One type, one place.
/// Users cannot change these; the `metrics` tool measures the right values.
public struct VoiceprintConfig: Sendable, Equatable {
    /// Which voiceprint kind the matcher uses.
    public var kind: VoiceprintKind = .plda

    /// Raw anchor: SpeakerKit's intra-file clustering threshold (sdk_findings section 2).
    public var raw = KindThresholds(acceptRadius: 0.6, highDistance: 0.35, mediumDistance: 0.50)

    /// No anchor exists for PLDA; same estimates until the calibration pass.
    public var plda = KindThresholds(acceptRadius: 0.6, highDistance: 0.35, mediumDistance: 0.50)

    /// Maximum distinct meetings counted per person (K).
    public var bestMeetingsPerPerson = 5

    /// Score weight for an inferred (LLM-set) tag.
    public var inferredTagWeight: Float = 0.4

    /// Speaking time (seconds) at which the speech weight saturates to 1.0.
    public var fullSpeechSeconds: Double = 60

    /// Score multiplier for a person who is a calendar invitee.
    public var inviteeBoost: Float = 1.5

    /// P2.score >= this ratio * P1.score triggers ambiguous.
    public var ambiguityScoreRatio: Float = 0.6

    /// |P1.dist - P2.dist| <= this gap triggers ambiguous.
    public var ambiguityDistanceGap: Float = 0.05

    /// High needs P2.score <= this ratio * P1.score.
    public var highMarginRatio: Float = 0.35

    /// High needs at least this many meetings counted.
    public var highMinMeetings = 3

    /// High needs at least this many confirmed meetings.
    public var highMinConfirmed = 2

    /// Medium with only inferred tags needs at least this many meetings.
    public var mediumMinInferred = 3

    /// Unnamed meeting count threshold for the "recurring unnamed" report line.
    public var unnamedMinMeetings = 2

    /// Maximum candidates reported for an ambiguous match.
    public var maxAmbiguousCandidates = 3

    /// Returns the thresholds for a given voiceprint kind.
    public func thresholds(for kind: VoiceprintKind) -> KindThresholds {
        switch kind {
        case .raw: raw
        case .plda: plda
        }
    }

    public static let `default` = VoiceprintConfig()

    public init() {}
}
