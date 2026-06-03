import Accelerate
import Foundation
import os

/// Tracks RMS levels to detect the zero-buffer failure mode.
/// Uses os_unfair_lock for real-time thread safety (no priority inversion).
final class RMSMonitor: @unchecked Sendable {
    private var _lock = os_unfair_lock()
    private var _consecutiveZeroSeconds: Double = 0
    let windowDuration: Double

    init(windowDuration: Double = 30.0) {
        self.windowDuration = windowDuration
    }

    var consecutiveZeroSeconds: Double {
        os_unfair_lock_lock(&_lock)
        defer { os_unfair_lock_unlock(&_lock) }
        return _consecutiveZeroSeconds
    }

    var isSuspectedFailure: Bool {
        consecutiveZeroSeconds >= windowDuration
    }

    func reset() {
        os_unfair_lock_lock(&_lock)
        _consecutiveZeroSeconds = 0
        os_unfair_lock_unlock(&_lock)
    }

    func processSamples(_ samples: UnsafePointer<Float>, count: Int, bufferDuration: Double) {
        let rms = Self.computeRMS(samples, count: count)

        os_unfair_lock_lock(&_lock)
        if rms == 0.0 {
            _consecutiveZeroSeconds += bufferDuration
        } else {
            _consecutiveZeroSeconds = 0
        }
        os_unfair_lock_unlock(&_lock)
    }

    static func computeRMS(_ samples: UnsafePointer<Float>, count: Int) -> Float {
        guard count > 0 else { return 0.0 }
        var meanSquare: Float = 0.0
        vDSP_measqv(samples, 1, &meanSquare, vDSP_Length(count))
        return sqrtf(meanSquare)
    }
}
