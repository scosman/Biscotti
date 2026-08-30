import DataStore
import Foundation

/// Renders transcript segments as the plain-text transcript format of
/// functional spec §5.3: one block per speaker turn — a `[MM:SS] Name` header
/// line, the spoken text below it, a blank line between turns. Consecutive
/// segments from the same speaker collapse into one turn; `HH:MM:SS` is used
/// from one hour up.
///
/// Deliberately independent of `Intelligence.TranscriptFormatter` (untimestamped,
/// drags in LocalLLM) and `MeetingDetailUI` (SwiftUI) — ~40 lines of pure code
/// beat either coupling (architecture §6.4).
enum TranscriptTextFormatter {
    static func text(segments: [SegmentData], names: [Int: String]) -> String {
        var turns: [String] = []
        var currentSpeakerID: Int?
        var currentName = ""
        var currentStartTime: TimeInterval = 0
        var currentText = ""

        func flushTurn() {
            if !currentText.isEmpty {
                turns.append("[\(timestamp(currentStartTime))] \(currentName)\n\(currentText)")
            }
            currentSpeakerID = nil
            currentName = ""
            currentText = ""
        }

        for segment in segments {
            let trimmed = segment.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }

            let name = segment.speakerID.flatMap { names[$0] } ?? segment.speakerLabel
            if let speakerID = segment.speakerID, speakerID == currentSpeakerID {
                currentText += " " + trimmed
            } else {
                flushTurn()
                currentSpeakerID = segment.speakerID
                currentName = name
                currentStartTime = segment.startTime
                currentText = trimmed
            }
        }
        flushTurn()

        return turns.joined(separator: "\n\n")
    }

    /// `MM:SS` below one hour, `HH:MM:SS` from 3600 s up.
    static func timestamp(_ interval: TimeInterval) -> String {
        let totalSeconds = max(0, Int(interval.rounded(.down)))
        let hours = totalSeconds / 3600
        let minutes = (totalSeconds % 3600) / 60
        let seconds = totalSeconds % 60
        if hours > 0 {
            return String(format: "%02d:%02d:%02d", hours, minutes, seconds)
        }
        return String(format: "%02d:%02d", minutes, seconds)
    }
}
