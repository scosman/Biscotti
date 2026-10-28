import Foundation

/// How much audio per track each stage of the live path holds, and when
/// audio counts as backfill.
public enum LiveAudioLimits {
    /// The most audio a live session retains per track. More means decodes
    /// fall behind, and the oldest undecoded audio is dropped as a gap.
    public static let sessionRetention: TimeInterval = 45

    /// Audio per track between the app's pump and the session: 8 chunks of
    /// 250 ms queued in the app's pipe and 8 more unacknowledged on the XPC
    /// connection.
    public static let inTransit: TimeInterval = 4

    /// How far past a track's transcribed time the app hands audio to the
    /// engine. The rest waits in the app, so the session never holds more
    /// than this plus what is in transit, which stays under its retention.
    public static let engineLead: TimeInterval = 36

    /// The most audio per track the app keeps for live use while the engine
    /// cannot take it: from Record until the engine runs, across restarts,
    /// and while it catches up. Older audio is lost to the live transcript
    /// (the saved transcript still has it). Kept as 16-bit samples, about
    /// 29 MB per track.
    public static let pumpBacklog: TimeInterval = 15 * 60

    /// Audio handed to the engine this far behind the newest captured audio
    /// is backfill.
    public static let backfillLag: TimeInterval = 5

    /// A catch-up decode takes up to this much of a track's backfill.
    public static let catchUpWindow: TimeInterval = 30
}
