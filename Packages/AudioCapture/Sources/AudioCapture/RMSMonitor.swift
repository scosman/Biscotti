import Accelerate

/// Tracks RMS levels to detect the zero-buffer failure mode.
///
/// Kept but **unwired** by default per phase 9 validation: the all-zero
/// tap failure did not reproduce on macOS 15. Exposed so it can be wired
/// if the failure ever surfaces.
public struct RMSMonitor: Sendable {
    private let windowDuration: Double
    private var consecutiveZeroSeconds: Double = 0

    public init(windowDuration: Double = 30.0) {
        self.windowDuration = windowDuration
    }

    /// Feed a buffer of PCM samples. Call once per render callback.
    public mutating func ingest(_ buffer: [Float], bufferDuration: Double) {
        let rms = Self.computeRMS(buffer)
        if rms == 0.0 {
            consecutiveZeroSeconds += bufferDuration
        } else {
            consecutiveZeroSeconds = 0
        }
    }

    /// `true` when the monitor has seen nothing but zeros for at least
    /// `windowDuration` seconds, indicating a probable capture failure.
    public var isSuspectedFailure: Bool {
        consecutiveZeroSeconds >= windowDuration
    }

    /// Resets the consecutive-zero counter.
    public mutating func reset() {
        consecutiveZeroSeconds = 0
    }

    /// Computes the root-mean-square of a Float buffer using vDSP.
    public static func computeRMS(_ samples: [Float]) -> Float {
        guard !samples.isEmpty else { return 0.0 }
        var meanSquare: Float = 0.0
        samples.withUnsafeBufferPointer { ptr in
            guard let base = ptr.baseAddress else { return }
            vDSP_measqv(base, 1, &meanSquare, vDSP_Length(samples.count))
        }
        return sqrtf(meanSquare)
    }
}
