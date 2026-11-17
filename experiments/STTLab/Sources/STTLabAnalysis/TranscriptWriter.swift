import Foundation

/// Writes plain-text and speaker-annotated transcript files for the report.
public enum TranscriptWriter {

    /// Write display-text transcript to `transcripts/<mid>/<engine>.txt`.
    public static func writePlainText(
        displayText: String,
        engine: EngineID,
        meetingID: String,
        outputDir: URL
    ) throws {
        let dir = outputDir.appendingPathComponent("transcripts/\(meetingID)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("\(engine.rawValue).txt")
        try displayText.write(to: url, atomically: true, encoding: .utf8)
    }

    /// Write speaker-annotated transcript to `transcripts/<mid>/<engine>.speakers.md`.
    public static func writeSpeakerAnnotated(
        aligned: AlignedTranscript,
        meetingID: String,
        outputDir: URL
    ) throws {
        let dir = outputDir.appendingPathComponent("transcripts/\(meetingID)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("\(aligned.engine.rawValue).speakers.md")

        var lines: [String] = []
        for seg in aligned.segments {
            let time = formatMmSs(seg.start)
            let speaker = seg.speaker.map { "Speaker \($0)" } ?? "Unknown"
            lines.append("[\(time)] \(speaker): \(seg.text)")
        }

        try lines.joined(separator: "\n").write(to: url, atomically: true, encoding: .utf8)
    }

    static func formatMmSs(_ seconds: Double) -> String {
        let m = Int(seconds) / 60
        let s = Int(seconds) % 60
        return "\(m):\(String(format: "%02d", s))"
    }
}
