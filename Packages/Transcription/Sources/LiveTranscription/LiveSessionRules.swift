import Foundation
import LiveTranscriptModel

/// What every live session accepts in its config.
enum LiveSessionRules {
    /// Any interval above the 45 s retention limit guarantees overflow, so this cap loses nothing.
    static let maximumUpdateInterval: TimeInterval = 60

    /// Two tracks recognized apart, in either order, or the one mixed track.
    static func isSupported(_ tracks: [LiveTrack]) -> Bool {
        tracks == [.mixed] || (tracks.count == 2 && Set(tracks) == [.mic, .system])
    }

    /// `Duration.seconds` traps on a value that is not finite or is above
    /// about 1e20 s; the spec's intervals are 1 to 4 s.
    static func isValidInterval(_ seconds: TimeInterval) -> Bool {
        seconds.isFinite && seconds > 0 && seconds <= maximumUpdateInterval
    }
}
