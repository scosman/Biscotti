import DataStore

/// Formats a transcript into plain-text turns for LLM consumption.
///
/// Output is compact (no timestamps) to conserve context window. Consecutive
/// segments from the same speaker are collapsed into a single turn.
public enum TranscriptFormatter {
    /// Renders a transcript as turn-per-line plain text.
    ///
    /// - Parameters:
    ///   - transcript: The transcript data with segments.
    ///   - names: Speaker ID -> resolved name overrides. Falls back to
    ///     `segment.speakerLabel` when no override exists.
    /// - Returns: Multi-line string, one line per speaker turn.
    public static func plain(
        _ transcript: TranscriptData, names: [Int: String]
    ) -> String {
        guard !transcript.segments.isEmpty else { return "" }

        var lines: [String] = []
        var currentSpeakerID: Int?
        var currentLabel = ""
        var currentText = ""

        for segment in transcript.segments {
            let label = speakerLabel(for: segment, names: names)
            let sameAsPrevious = segment.speakerID != nil
                && segment.speakerID == currentSpeakerID

            if sameAsPrevious {
                // Collapse consecutive same-speaker segments
                currentText += " " + segment.text.trimmingCharacters(
                    in: .whitespaces
                )
            } else {
                // Flush previous turn
                if !currentText.isEmpty {
                    lines.append("\(currentLabel): \(currentText)")
                }
                currentSpeakerID = segment.speakerID
                currentLabel = label
                currentText = segment.text.trimmingCharacters(
                    in: .whitespaces
                )
            }
        }

        // Flush the last turn
        if !currentText.isEmpty {
            lines.append("\(currentLabel): \(currentText)")
        }

        return lines.joined(separator: "\n")
    }

    private static func speakerLabel(
        for segment: SegmentData, names: [Int: String]
    ) -> String {
        if let id = segment.speakerID, let name = names[id] {
            return name
        }
        return segment.speakerLabel
    }
}
