import Foundation

/// The live transcript's state, as the drawer's toggle shows it.
public enum LiveStatus: Equatable, Sendable {
    /// No recording, or live transcription is off.
    case off
    /// The engine is starting and no text has come yet. The first start in a
    /// new build can take minutes while macOS compiles the model.
    case starting
    case live
    /// The live text is more than 10 s behind the audio on a track.
    case catchingUp
    case paused(PauseReason)
    case unavailable(UnavailableReason)
}

public enum PauseReason: Equatable, Sendable {
    /// Paused at a serious heat level; it resumes on its own.
    case lowPowerHeat
}

public enum UnavailableReason: Equatable, Sendable {
    /// The live engine's model is not downloaded.
    case modelMissing
    case languageUnsupported
    /// The engine failed twice in this recording.
    case stopped
}

/// A request for the drawer to scroll to a moment of the recording.
public struct RevealRequest: Equatable, Sendable {
    /// Seconds on the recording timeline.
    public let time: TimeInterval
    /// Tells two requests for the same time apart.
    public let id: UUID

    public init(time: TimeInterval, id: UUID = UUID()) {
        self.time = time
        self.id = id
    }
}

/// Whether the live engine's model is on this Mac.
public enum LiveModelState: Equatable, Sendable {
    case missing
    /// Downloading; the message names the stage.
    case downloading(String)
    case ready
    case failed(String)
}

/// How a recording's live session ended after Stop.
public enum LiveFinishResult: Equatable, Sendable {
    /// The engine finished its last words, and the draft has them.
    case finished
    /// The deadline passed first. The draft keeps what it had, with its tail
    /// marked incomplete. The worker may be stuck in a decode.
    case timedOut
    /// The engine ended before it could finish (the worker was lost). The
    /// draft keeps what it had, with its tail marked incomplete.
    case engineLost
    /// A new recording, or turning live transcription off, cut the finish short.
    case cancelled
    /// No engine was running: live transcription was off, unavailable or
    /// still starting.
    case nothingToFinish
    /// Stop came while a language change waited for the old engine's last
    /// words, which a decode stuck in the worker can hold for good. As after
    /// `.timedOut`, the final pass needs a fresh worker.
    case languageSwitchUnfinished

    /// Whether the worker may be stuck in a decode, so the final pass should
    /// not wait for it.
    public var mayLeaveWorkerStuck: Bool {
        self == .timedOut || self == .languageSwitchUnfinished
    }
}
