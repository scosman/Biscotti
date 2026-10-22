import Foundation

/// Manages the results folder: run.json (sessions), per-meeting apple.json, and log.txt.
public enum ResultsWriter {
    /// Create the results directory structure if needed.
    public static func ensureResultsDir(at url: URL) throws {
        let fm = FileManager.default
        try fm.createDirectory(
            at: url.appendingPathComponent("meetings"),
            withIntermediateDirectories: true
        )
    }

    // MARK: - run.json

    private static func runFileURL(_ resultsURL: URL) -> URL {
        resultsURL.appendingPathComponent("run.json")
    }

    /// Load the existing RunFile, or create an empty one.
    public static func loadRunFile(from resultsURL: URL) -> RunFile {
        let url = runFileURL(resultsURL)
        guard FileManager.default.fileExists(atPath: url.path),
              let file: RunFile = try? JSONFiles.read(from: url)
        else {
            return RunFile()
        }
        return file
    }

    /// Append a session to the RunFile and write it atomically.
    public static func writeRunFile(_ file: RunFile, to resultsURL: URL) throws {
        try JSONFiles.write(file, to: runFileURL(resultsURL))
    }

    // MARK: - apple.json

    /// Write a meeting result to `meetings/<mid>/apple.json`.
    public static func writeMeetingResult(
        _ result: AppleMeetingResult,
        meetingID: String,
        resultsURL: URL
    ) throws {
        let meetingDir = resultsURL
            .appendingPathComponent("meetings")
            .appendingPathComponent(meetingID)
        try FileManager.default.createDirectory(at: meetingDir, withIntermediateDirectories: true)
        let url = meetingDir.appendingPathComponent("apple.json")
        try JSONFiles.write(result, to: url)
    }

    /// Load a previously written meeting result, if any.
    public static func loadMeetingResult(
        meetingID: String,
        resultsURL: URL
    ) -> AppleMeetingResult? {
        let url = resultsURL
            .appendingPathComponent("meetings")
            .appendingPathComponent(meetingID)
            .appendingPathComponent("apple.json")
        return try? JSONFiles.read(from: url)
    }

    // MARK: - log.txt

    public static func logURL(_ resultsURL: URL) -> URL {
        resultsURL.appendingPathComponent("log.txt")
    }
}
