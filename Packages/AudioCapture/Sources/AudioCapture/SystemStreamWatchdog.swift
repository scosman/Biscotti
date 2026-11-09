import Foundation

/// Decides whether the system-audio stream has stalled.
///
/// The Core Audio process tap can keep "running" while delivering either
/// nothing at all or only zero-filled buffers -- observed when AirPods
/// switch from A2DP to HFP as a call starts (GitHub #88). The default
/// output device does not change, so no route-change event fires and the
/// system track is silent for the rest of the session. This watchdog is
/// the trigger that was missing: `AudioRecorder` polls it and runs the
/// existing file-preserving `reconnect()` path when it reports a stall.
///
/// Pure function of timestamps so it is unit-testable without hardware.
/// `AudioRecorder` owns the polling task, the mic gate and the cooldown.
public enum SystemStreamWatchdog {
    /// Tuning for the watchdog. Injected into `AudioRecorder` so tests can
    /// use short windows; production uses `.default`.
    public struct Configuration: Sendable {
        /// How long the system stream may go without a non-zero buffer
        /// (while the mic is audibly live) before it counts as stalled.
        /// 3 s is well above the ~200-500 ms the HAL needs to settle a
        /// route or rate change, and short enough that a stalled call
        /// loses only a few seconds of the other side.
        public var stallWindow: Duration

        /// How often the recorder samples both engines' `streamHealth`.
        public var pollInterval: Duration

        /// Minimum time between stall-triggered reconnects. Stops a tap that
        /// genuinely cannot deliver audio (e.g. permission revoked mid-call)
        /// from being torn down and rebuilt every `stallWindow`.
        public var reconnectCooldown: Duration

        public init(
            stallWindow: Duration = .seconds(3),
            pollInterval: Duration = .milliseconds(500),
            reconnectCooldown: Duration = .seconds(30)
        ) {
            self.stallWindow = stallWindow
            self.pollInterval = pollInterval
            self.reconnectCooldown = reconnectCooldown
        }

        public static let `default` = Configuration()
    }

    /// Why the stream is considered stalled.
    enum Stall: Equatable {
        /// The IOProc has delivered no buffer at all for the whole window.
        case noBuffers
        /// Buffers keep arriving but every sample in the window was zero.
        case allZero
    }

    /// Evaluates one watchdog tick.
    ///
    /// - Parameters:
    ///   - system: the system engine's health snapshot.
    ///   - mic: the mic engine's health snapshot. The mic must have delivered
    ///     a non-zero buffer inside the window, otherwise the room is simply
    ///     quiet (or the mic is muted) and system silence proves nothing.
    ///   - armedAtNanos: host time of the last start/reconnect. Nothing
    ///     before it counts, so a fresh tap gets the full window to warm up.
    ///   - nowNanos: current host time.
    ///   - stallWindowNanos: `Configuration.stallWindow` in nanoseconds.
    /// - Returns: the stall kind, or `nil` while the stream looks healthy.
    static func evaluate(
        system: StreamHealth,
        mic: StreamHealth,
        armedAtNanos: UInt64,
        nowNanos: UInt64,
        stallWindowNanos: UInt64
    ) -> Stall? {
        guard nowNanos > stallWindowNanos else { return nil }
        let windowStart = nowNanos - stallWindowNanos

        // Not yet armed for a full window: the tap is still warming up.
        guard armedAtNanos <= windowStart else { return nil }

        // Mic gate: only trust system silence while the mic is audibly live.
        guard mic.lastNonZeroHostNanos > windowStart else { return nil }

        // Healthy: a non-zero system buffer landed inside the window.
        guard system.lastNonZeroHostNanos <= windowStart else { return nil }

        return system.lastBufferHostNanos <= windowStart ? .noBuffers : .allZero
    }
}

extension Duration {
    /// Whole nanoseconds, saturating at `UInt64.max` for absurd values.
    var nanoseconds: UInt64 {
        let (seconds, attoseconds) = components
        guard seconds >= 0 else { return 0 }
        let (whole, overflow) = UInt64(seconds).multipliedReportingOverflow(by: 1_000_000_000)
        guard !overflow else { return .max }
        return whole + UInt64(attoseconds / 1_000_000_000)
    }
}
