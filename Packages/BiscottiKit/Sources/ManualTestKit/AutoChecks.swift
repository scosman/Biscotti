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

    /// Checks that no `BiscottiLLM` service process is running.
    ///
    /// After XPC inference + connection close, the service should have exited
    /// (`_exit(0)` on last-connection invalidation). This check uses `pgrep -x`
    /// to verify no orphaned service remains; it returns a pass when no matching
    /// process is found (exit code 1 from pgrep) and a fail when one is still
    /// alive.
    public static func checkNoLLMServiceRunning() -> CheckOutcome {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/pgrep")
        process.arguments = ["-x", "BiscottiLLM"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()

        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            return CheckOutcome(
                passed: false,
                detail: "Failed to run pgrep: \(error.localizedDescription)"
            )
        }

        if process.terminationStatus == 0 {
            // pgrep found a matching process — service is still alive
            let output = String(
                data: pipe.fileHandleForReading.readDataToEndOfFile(),
                encoding: .utf8
            )?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "unknown"
            return CheckOutcome(
                passed: false,
                detail: "BiscottiLLM service still running (pid: \(output))"
            )
        }

        return CheckOutcome(
            passed: true,
            detail: "No BiscottiLLM service process found (reclaimed)"
        )
    }

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
