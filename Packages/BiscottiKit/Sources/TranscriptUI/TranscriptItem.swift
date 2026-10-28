import Foundation

/// One row of the bubble transcript: a bubble, a gap marker or the start marker.
public struct TranscriptItem: Identifiable, Equatable, Sendable {
    public enum Kind: Equatable, Sendable {
        case bubble(Bubble)
        /// A stretch that may have held speech and has no live text:
        /// "Not transcribed live · 0:12", or "Audio paused while switching
        /// devices · 0:07" when nothing was recorded either.
        case gap(startTime: TimeInterval, duration: TimeInterval, cause: GapCause)
        /// "LIVE TRANSCRIPT STARTED AT 4:12": live transcription began mid-recording.
        case startMarker(time: TimeInterval)
    }

    /// Stable across updates: the segment UUID, the live row UUID,
    /// `gap-<milliseconds>` or `start-marker`.
    public let id: String
    public let kind: Kind

    public init(id: String, kind: Kind) {
        self.id = id
        self.kind = kind
    }

    /// The recording time this item covers, used to reveal a time.
    /// A marker without a duration covers only its start.
    public var timeRange: Range<TimeInterval> {
        switch kind {
        case let .bubble(bubble):
            bubble.startTime ..< max(bubble.endTime, bubble.startTime)
        case let .gap(startTime, duration, _):
            startTime ..< startTime + max(duration, 0)
        case let .startMarker(time):
            time ..< time
        }
    }

    public var startTime: TimeInterval {
        timeRange.lowerBound
    }

    /// The bubble, when this item is one.
    public var bubble: Bubble? {
        if case let .bubble(bubble) = kind { return bubble }
        return nil
    }
}

/// Why a gap marker's stretch has no live text. Chosen by the user in the
/// hardware review (25 October 2026): a device switch gets its own marker,
/// because the recording has nothing there either.
public enum GapCause: Equatable, Sendable {
    /// Recorded, but missed by the live transcript; the saved transcript
    /// includes it.
    case notTranscribedLive
    /// Capture paused while the microphone or speakers switched; nothing was
    /// recorded.
    case deviceSwitch
}

/// One speech bubble.
public struct Bubble: Equatable, Sendable {
    public enum Side: Equatable, Sendable {
        case leading
        case trailing
    }

    public var side: Side
    /// Shown above the first bubble of a speaker run.
    public var label: RunLabel?
    /// True for the first bubble of a run, labeled or not; runs are spaced
    /// further apart than the bubbles within one run.
    public var startsRun: Bool
    public var startTime: TimeInterval
    public var endTime: TimeInterval
    public var settledText: String
    /// Live only: the text that may still change.
    public var tailText: String
    public var showsTypingDots: Bool
    /// Saved transcripts only; enables the speaker-mapping sheet.
    public var speakerID: Int?
    /// The speaker VoiceOver names for this bubble ("You", "Priya").
    /// Nil for mixed-track rows, which name no speaker.
    public var spokenName: String?

    public init(
        side: Side,
        label: RunLabel? = nil,
        startsRun: Bool = true,
        startTime: TimeInterval,
        endTime: TimeInterval,
        settledText: String,
        tailText: String = "",
        showsTypingDots: Bool = false,
        speakerID: Int? = nil,
        spokenName: String? = nil
    ) {
        self.side = side
        self.label = label
        self.startsRun = startsRun
        self.startTime = startTime
        self.endTime = endTime
        self.settledText = settledText
        self.tailText = tailText
        self.showsTypingDots = showsTypingDots
        self.speakerID = speakerID
        self.spokenName = spokenName
    }

    /// Settled text followed by the tail: what find searches and Copy copies.
    public var fullText: String {
        settledText + tailText
    }
}

/// The label above a speaker run: "Priya · 0:31".
public struct RunLabel: Equatable, Sendable {
    /// Drawn in `sage`.
    public static let youColorKey = "you"
    /// Drawn in `inkSecondary`.
    public static let othersColorKey = "others"

    public var name: String
    public var colorKey: String
    public var time: TimeInterval

    public init(name: String, colorKey: String, time: TimeInterval) {
        self.name = name
        self.colorKey = colorKey
        self.time = time
    }
}

/// How live rows are labeled.
public enum LiveLabelStyle: Equatable, Sendable {
    /// No labels: the drawer, where sides already show the speaker.
    case none
    /// "You" and "Others" run labels: the Transcript tab's draft.
    case youOthers
}

/// Whether the list follows new items.
public enum FollowMode: Equatable, Sendable {
    /// Saved transcripts and drafts: the list never scrolls by itself.
    case never
    /// The live drawer: the list follows new text while at the bottom.
    case live
}
