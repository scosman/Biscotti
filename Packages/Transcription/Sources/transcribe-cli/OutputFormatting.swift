import Foundation
import Transcription

// MARK: - Output writer abstraction

/// Abstraction for writing to stdout/stderr, injectable for testing.
protocol OutputWriter: Sendable {
    func writeStdout(_ text: String)
    func writeStderr(_ text: String)
    /// Write to stderr without a trailing newline (for `\r` progress overwrites).
    func writeStderrInline(_ text: String)
}

/// Real output writer that uses FileHandle for stdout/stderr.
struct StandardOutputWriter: OutputWriter {
    func writeStdout(_ text: String) {
        FileHandle.standardOutput.write(Data((text + "\n").utf8))
    }

    func writeStderr(_ text: String) {
        FileHandle.standardError.write(Data((text + "\n").utf8))
    }

    func writeStderrInline(_ text: String) {
        FileHandle.standardError.write(Data(text.utf8))
    }
}

// MARK: - JSON formatting

/// Encode a `TranscriptResult` as pretty-printed JSON with sorted keys
/// and ISO 8601 dates. Deterministic output suitable for machine consumption.
func formatResultJSON(_ result: TranscriptResult) throws -> String {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    encoder.dateEncodingStrategy = .iso8601

    let data = try encoder.encode(result)
    guard let jsonString = String(data: data, encoding: .utf8) else {
        throw FormatError.encodingFailed
    }
    return jsonString
}

enum FormatError: Error {
    case encodingFailed
}

// MARK: - Human-readable text formatting

/// Format a `TranscriptResult` as human-readable text with speaker labels,
/// timestamps, and optional word-level detail.
func formatResultText(_ result: TranscriptResult) -> String {
    var lines: [String] = []

    lines.append("Transcript Result")
    lines.append("=================")
    lines.append("Model:      \(result.modelVersion)")
    lines.append("Language:   \(result.language)")
    lines.append("Speakers:   \(result.speakerCount)")
    lines.append("Segments:   \(result.segments.count)")
    lines.append("Duration:   \(String(format: "%.1f", result.processingDuration))s processing time")
    lines.append("Created:    \(result.createdAt)")
    lines.append("")

    if !result.speakerEmbeddings.isEmpty {
        lines.append("Speaker Embeddings")
        lines.append("------------------")
        for (speakerID, embedding) in result.speakerEmbeddings.sorted(by: { $0.key < $1.key }) {
            lines.append("  Speaker \(speakerID): \(embedding.count)-dim vector")
        }
        lines.append("")
    }

    lines.append("Transcript")
    lines.append("----------")
    for segment in result.segments {
        let timeRange = formatTime(segment.startTime) + " -> " + formatTime(segment.endTime)
        lines.append("[\(timeRange)] \(segment.speakerLabel):")
        lines.append("  \(segment.text)")

        if let words = segment.words, !words.isEmpty {
            let wordDetails = words.map { entry in
                "\(entry.word)(\(String(format: "%.0f%%", entry.probability * 100)))"
            }.joined(separator: " ")
            lines.append("  Words: \(wordDetails)")
        }
        lines.append("")
    }

    return lines.joined(separator: "\n")
}

private func formatTime(_ seconds: TimeInterval) -> String {
    let minutes = Int(seconds) / 60
    let secs = Int(seconds) % 60
    let frac = Int((seconds - Double(Int(seconds))) * 10)
    return String(format: "%02d:%02d.%d", minutes, secs, frac)
}
