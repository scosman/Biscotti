import Foundation

/// The audio source a live row was transcribed from.
///
/// `.mic` is "You" and `.system` is "Others". `.mixed` is the one-track
/// fallback, whose rows name no speaker.
public enum LiveTrack: String, Codable, Sendable, Hashable {
    case mic
    case system
    case mixed
}

/// The engine that produces live text. The app runs only Whisper; the kind
/// stays in `LiveSessionConfig` as wire format, and the replay harness's
/// reference branch adds a second engine (SpeechAnalyzer).
public enum LiveEngineKind: String, Codable, Sendable, Hashable {
    case whisper
}

/// The language policy of a live session.
public enum LiveLanguage: Codable, Sendable, Hashable {
    case english
    /// Identify the language from the first speech, then keep it.
    case detect
    /// A locale identifier: the language Detect found, kept when the
    /// session restarts.
    case locale(String)
}

/// One bubble of live text on one track.
///
/// Times are seconds on the recording timeline. `settledText` only grows
/// during a recording; `tailText` is the part that may still change and is
/// replaced on every update.
public struct LiveRow: Codable, Sendable, Equatable, Identifiable {
    /// Stable for the row's lifetime, so the view keeps the bubble's identity.
    public let id: UUID
    public var track: LiveTrack
    public var startTime: TimeInterval
    public var endTime: TimeInterval
    public var settledText: String
    public var tailText: String
    /// True once no more text can join this row. A closed row has no tail.
    public var isClosed: Bool
    /// True when text was committed without agreement to bound retained audio.
    public var isForcedBoundary: Bool
    /// True when finishing timed out before the tail could settle.
    public var isIncomplete: Bool

    public init(
        id: UUID = UUID(),
        track: LiveTrack,
        startTime: TimeInterval,
        endTime: TimeInterval,
        settledText: String = "",
        tailText: String = "",
        isClosed: Bool = false,
        isForcedBoundary: Bool = false,
        isIncomplete: Bool = false
    ) {
        self.id = id
        self.track = track
        self.startTime = startTime
        self.endTime = endTime
        self.settledText = settledText
        self.tailText = tailText
        self.isClosed = isClosed
        self.isForcedBoundary = isForcedBoundary
        self.isIncomplete = isIncomplete
    }

    /// False for a row whose tail was withdrawn before any text settled.
    /// Such rows stay in the update stream so their ID can be reused; views hide them.
    public var hasText: Bool {
        !settledText.isEmpty || !tailText.isEmpty
    }
}

/// A stretch of a track that the live transcript does not cover.
public struct LiveGap: Codable, Sendable, Equatable {
    public enum Reason: String, Codable, Sendable {
        case queueOverflow
        case captureGap
        case paused
        case engineRestart
    }

    public var track: LiveTrack
    public var startTime: TimeInterval
    public var duration: TimeInterval
    public var reason: Reason
    /// True when the live path had this stretch's audio and every 250 ms of
    /// it was silence, so nothing was missed. False when its audio never
    /// arrived, which says nothing about what it held.
    public var isSilent: Bool

    public init(track: LiveTrack, startTime: TimeInterval, duration: TimeInterval, reason: Reason, isSilent: Bool = false) {
        self.track = track
        self.startTime = startTime
        self.duration = duration
        self.reason = reason
        self.isSilent = isSilent
    }

    private enum CodingKeys: String, CodingKey {
        case track, startTime, duration, reason, isSilent
    }

    /// A gap encoded without `isSilent` is not silent.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        track = try container.decode(LiveTrack.self, forKey: .track)
        startTime = try container.decode(TimeInterval.self, forKey: .startTime)
        duration = try container.decode(TimeInterval.self, forKey: .duration)
        reason = try container.decode(Reason.self, forKey: .reason)
        isSilent = try container.decodeIfPresent(Bool.self, forKey: .isSilent) ?? false
    }

    public var endTime: TimeInterval {
        startTime + duration
    }
}

/// What changed on one track since the previous update.
public struct LiveTrackUpdate: Codable, Sendable, Equatable {
    public var sessionID: UUID
    public var generation: Int
    public var track: LiveTrack
    public var revision: Int
    /// Rows created or changed since the last update, in time order.
    public var rows: [LiveRow]
    public var gaps: [LiveGap]
    /// Audio decoded at least once.
    public var transcribedThrough: TimeInterval
    /// Audio resolved: settled text, processed silence or a recorded gap.
    public var settledThrough: TimeInterval
    public var detectedLanguage: String?
    public var decodeMilliseconds: Double?

    public init(
        sessionID: UUID,
        generation: Int,
        track: LiveTrack,
        revision: Int,
        rows: [LiveRow],
        gaps: [LiveGap],
        transcribedThrough: TimeInterval,
        settledThrough: TimeInterval,
        detectedLanguage: String? = nil,
        decodeMilliseconds: Double? = nil
    ) {
        self.sessionID = sessionID
        self.generation = generation
        self.track = track
        self.revision = revision
        self.rows = rows
        self.gaps = gaps
        self.transcribedThrough = transcribedThrough
        self.settledThrough = settledThrough
        self.detectedLanguage = detectedLanguage
        self.decodeMilliseconds = decodeMilliseconds
    }

    /// Folds a later update for the same track into this one, so pending
    /// updates can wait without any being dropped: rows keep their latest
    /// version by ID, gaps accumulate, and everything else takes the later value.
    public mutating func merge(_ later: LiveTrackUpdate) {
        for row in later.rows {
            if let index = rows.firstIndex(where: { $0.id == row.id }) {
                rows[index] = row
            } else {
                rows.append(row)
            }
        }
        rows.sort { $0.startTime < $1.startTime }
        gaps += later.gaps
        revision = later.revision
        transcribedThrough = later.transcribedThrough
        settledThrough = later.settledThrough
        detectedLanguage = later.detectedLanguage ?? detectedLanguage
        decodeMilliseconds = later.decodeMilliseconds ?? decodeMilliseconds
    }
}

/// Everything an engine needs to start a live session.
public struct LiveSessionConfig: Codable, Sendable, Equatable {
    public var sessionID: UUID
    /// Increases when a session restarts, so updates from the old one are ignored.
    public var generation: Int
    /// Kept as wire format; every session the app starts is `.whisper`.
    public var engine: LiveEngineKind
    /// The Whisper model folder name, e.g. "openai_whisper-large-v3-v20240930_626MB".
    public var whisperModel: String?
    /// `[.mic, .system]` or `[.mixed]`.
    public var tracks: [LiveTrack]
    /// Seconds between decodes of one track.
    public var updateInterval: TimeInterval
    public var language: LiveLanguage
    public var vocabulary: [String]

    public init(
        sessionID: UUID,
        generation: Int,
        engine: LiveEngineKind,
        whisperModel: String?,
        tracks: [LiveTrack],
        updateInterval: TimeInterval,
        language: LiveLanguage,
        vocabulary: [String]
    ) {
        self.sessionID = sessionID
        self.generation = generation
        self.engine = engine
        self.whisperModel = whisperModel
        self.tracks = tracks
        self.updateInterval = updateInterval
        self.language = language
        self.vocabulary = vocabulary
    }
}
