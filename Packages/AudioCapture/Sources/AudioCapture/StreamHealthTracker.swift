import AudioToolbox
import Foundation
import Synchronization

/// Snapshot of a capture stream's recent buffer flow, in host-clock
/// nanoseconds (`AudioConvertHostTimeToNanos`). Zero means "never".
///
/// Engines publish this so `AudioRecorder` can tell a stream that has
/// silently stopped delivering audio (the Core Audio tap after an
/// AirPods A2DP → HFP switch, GitHub #88) from one that is merely quiet.
public struct StreamHealth: Sendable, Equatable {
    /// Host time of the most recent hardware buffer, zero-filled or not.
    public var lastBufferHostNanos: UInt64
    /// Host time of the most recent buffer containing a non-zero sample.
    public var lastNonZeroHostNanos: UInt64

    public init(lastBufferHostNanos: UInt64, lastNonZeroHostNanos: UInt64) {
        self.lastBufferHostNanos = lastBufferHostNanos
        self.lastNonZeroHostNanos = lastNonZeroHostNanos
    }

    /// No buffer has been observed (or the engine does not report health).
    public static let unknown = StreamHealth(lastBufferHostNanos: 0, lastNonZeroHostNanos: 0)
}

/// Current host-clock time in the same units as `StreamHealth`.
func hostClockNanos() -> UInt64 {
    AudioConvertHostTimeToNanos(mach_absolute_time())
}

/// Lock-free recorder of buffer-flow timestamps shared between an
/// engine's real-time callback (producer of `recordBuffer`), its writer
/// thread (producer of `recordNonZero`) and the recorder's watchdog
/// (reader of `snapshot`). Both stores are plain atomics, so the
/// real-time thread never allocates or blocks.
final class StreamHealthTracker: Sendable {
    private let lastBuffer = Atomic<UInt64>(0)
    private let lastNonZero = Atomic<UInt64>(0)

    /// Called from the audio callback for every delivered buffer.
    /// Falls back to the current host time when the buffer carries no
    /// valid timestamp (`hostTime == 0`).
    func recordBuffer(hostTime: UInt64) {
        let nanos = hostTime > 0 ? AudioConvertHostTimeToNanos(hostTime) : hostClockNanos()
        lastBuffer.store(nanos, ordering: .releasing)
    }

    /// Called from the writer thread after scanning a buffer's samples.
    func recordNonZero(hostNanos: UInt64) {
        let nanos = hostNanos > 0 ? hostNanos : hostClockNanos()
        lastNonZero.store(nanos, ordering: .releasing)
    }

    /// Clears both timestamps for a new session.
    func reset() {
        lastBuffer.store(0, ordering: .releasing)
        lastNonZero.store(0, ordering: .releasing)
    }

    var snapshot: StreamHealth {
        StreamHealth(
            lastBufferHostNanos: lastBuffer.load(ordering: .acquiring),
            lastNonZeroHostNanos: lastNonZero.load(ordering: .acquiring)
        )
    }

    /// `true` if any sample is non-zero. Early-exits on the first hit, so
    /// the common (audible) case costs a handful of comparisons.
    static func containsNonZero(_ samples: UnsafeBufferPointer<Float>) -> Bool {
        samples.contains { $0 != 0 }
    }
}
