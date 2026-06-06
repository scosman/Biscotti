import Foundation
import os
import Synchronization

private let logger = Logger(subsystem: "net.scosman.biscotti.audiocapture", category: "PermissionCheck")

/// Detects probable system-audio permission denial by monitoring the
/// first ~2 seconds of system audio buffers for all-zero content.
///
/// There is no public API to check system-audio (screen recording)
/// permission status. The only signal is silence: if the tap delivers
/// nothing but zeros for the first ~2 s, the user likely hasn't granted
/// the permission. The library reports this; it does not own TCC prompts.
final class LiveSystemPermissionChecker: SystemPermissionChecker, @unchecked Sendable {
    /// Atomic flags avoid NSLock in async `probableDenied()`.
    /// `totalDurationCentiseconds` stores duration * 100 as Int (atomics need integer).
    private let totalDurationCentiseconds = Atomic<Int>(0)
    private let hasNonZero = Atomic<Bool>(false)

    /// The window (in seconds) of initial audio to check.
    private let checkWindowCentiseconds: Int = 200 // 2.0 seconds

    /// Fast check for callers to avoid per-buffer allocation once the
    /// permission-detection window has elapsed.
    var isWithinCheckWindow: Bool {
        totalDurationCentiseconds.load(ordering: .acquiring) < checkWindowCentiseconds
    }

    /// Called from the writer thread with each batch of system audio samples.
    /// Accepts an `UnsafeBufferPointer` to avoid allocating a `[Float]` copy
    /// on every callback.
    func ingestSamples(_ samples: UnsafeBufferPointer<Float>, duration: Double) {
        // Only check the first ~2 seconds of audio.
        guard isWithinCheckWindow else { return }

        let centiseconds = Int(duration * 100)
        totalDurationCentiseconds.wrappingAdd(centiseconds, ordering: .releasing)

        if !hasNonZero.load(ordering: .acquiring) {
            for sample in samples where sample != 0.0 {
                hasNonZero.store(true, ordering: .releasing)
                break
            }
        }
    }

    func probableDenied() async -> Bool {
        // If we haven't accumulated enough audio yet, we can't tell.
        guard totalDurationCentiseconds.load(ordering: .acquiring) >= checkWindowCentiseconds else { return false }
        return !hasNonZero.load(ordering: .acquiring)
    }

    /// Resets for a new capture session.
    func reset() {
        totalDurationCentiseconds.store(0, ordering: .releasing)
        hasNonZero.store(false, ordering: .releasing)
    }
}
