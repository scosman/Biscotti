import Accelerate

/// The live path's one silence test. The session uses it to skip silent
/// audio and to time its tail rules; the app uses it to tell whether audio
/// the live path dropped held anything.
public enum AudioLevel {
    /// −45 dBFS as a linear RMS value. Quieter audio is treated as silence.
    public static let silenceThreshold = Float(pow(10.0, -45.0 / 20.0))
    /// 250 ms at 16 kHz, the pump's chunk length.
    public static let frameLength = 4000

    /// True when every 250 ms frame is below −45 dBFS. Empty audio is silent.
    ///
    /// The spec tests "the new audio's RMS". Averaged over seconds of new
    /// audio, a short quiet word such as "no" falls below the threshold and
    /// would be skipped without a gap; it would also disagree with the tail
    /// rules, which count silent chunks. So both use this one per-frame test.
    public static func isSilent(_ samples: ArraySlice<Float>) -> Bool {
        stride(from: samples.startIndex, to: samples.endIndex, by: frameLength).allSatisfy { start in
            vDSP.rootMeanSquare(samples[start ..< min(start + frameLength, samples.endIndex)]) < silenceThreshold
        }
    }

    public static func isSilent(_ samples: [Float]) -> Bool {
        isSilent(samples[...])
    }
}
