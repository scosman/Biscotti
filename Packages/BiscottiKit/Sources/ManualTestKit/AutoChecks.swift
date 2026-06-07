import Foundation

/// Pure-function auto-check helpers used by the test scripts' `.autoCheck` steps.
/// These are the automatable assertions the harness runs — no Core Audio or XPC needed.
public enum AutoChecks {
    /// Default minimum file size in bytes (10 KB) — a file below this is suspiciously small
    /// for any real audio recording, even a very short one at 64 kbps.
    public static let defaultMinBytes: Int = 10240

    /// Checks that two `.aac` files exist at the given URLs and each exceeds `minBytes`.
    public static func checkAACFilesExist(
        micURL: URL,
        systemURL: URL,
        minBytes: Int = defaultMinBytes,
        fileManager: FileManager = .default
    ) -> CheckOutcome {
        for (label, url) in [("mic", micURL), ("system", systemURL)] {
            guard fileManager.fileExists(atPath: url.path) else {
                return CheckOutcome(passed: false, detail: "\(label) file missing: \(url.lastPathComponent)")
            }
            guard let attrs = try? fileManager.attributesOfItem(atPath: url.path),
                  let size = attrs[.size] as? Int
            else {
                return CheckOutcome(passed: false, detail: "Cannot read size of \(label) file")
            }
            if size < minBytes {
                return CheckOutcome(
                    passed: false,
                    detail: "\(label) file too small: \(size) bytes (minimum \(minBytes))"
                )
            }
        }
        return CheckOutcome(passed: true, detail: "Both .aac files exist with sane sizes")
    }

    /// Tolerance (in seconds) for the segment-past-duration check. Accounts for minor
    /// floating-point rounding in timestamp arithmetic.
    public static let segmentTimeTolerance: Double = 0.5

    /// Checks that no transcript segment's end time exceeds the audio duration.
    ///
    /// This catches the classic Whisper end-of-audio hallucination where a trailing
    /// segment is timestamped past the actual file length.
    public static func checkNoSegmentPastDuration(
        segmentEndTimes: [Double],
        audioDuration: Double,
        tolerance: Double = segmentTimeTolerance
    ) -> CheckOutcome {
        let violators = segmentEndTimes.filter { $0 > audioDuration + tolerance }
        if violators.isEmpty {
            return CheckOutcome(
                passed: true,
                detail: "All \(segmentEndTimes.count) segments within audio duration (\(audioDuration)s)"
            )
        }
        let formatted = violators.map { String(format: "%.1fs", $0) }.joined(separator: ", ")
        return CheckOutcome(
            passed: false,
            detail: "\(violators.count) segment(s) past audio duration (\(audioDuration)s): \(formatted)"
        )
    }
}
