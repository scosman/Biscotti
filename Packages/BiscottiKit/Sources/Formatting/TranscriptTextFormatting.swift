import DataStore
import Foundation

/// The single plain-text transcript format (functional spec §4), used for
/// the meeting detail Copy button, the CSV `transcript` column, and parsed
/// back on import. Deliberately both human-readable and machine-parseable:
/// a speaker turn is a `[M:SS] Name` header line followed by the spoken
/// text, with one blank line between turns.
public enum TranscriptTextFormatting {
    // MARK: - Display name

    /// The display name for a segment's speaker: the assigned person name
    /// when the segment's `speakerID` is mapped in `names`, otherwise the
    /// original diarization `speakerLabel`.
    ///
    /// Shared by the transcript row (`TranscriptListView`) and `render` so
    /// on-screen and copied text resolve names identically.
    public static func displayName(
        for segment: SegmentData, names: [Int: String]
    ) -> String {
        if let sid = segment.speakerID, let assignedName = names[sid] {
            return assignedName
        }
        return segment.speakerLabel
    }

    // MARK: - Render

    /// Builds the plain-text rendering of a transcript.
    ///
    /// Format per turn:
    /// ```
    /// [0:23] Steve
    /// Let's get started.
    /// ```
    /// Blank line between turns. Consecutive segments sharing the same
    /// non-nil `speakerID` collapse into one turn, their text joined by a
    /// space — segment boundaries are diarization artifacts, and a header
    /// per fragment makes both the Copy output and the CSV unreadable.
    /// Segments with nil `speakerID` never collapse. Blank segments are
    /// dropped. Timestamps are `M:SS`, or `H:MM:SS` from one hour up.
    public static func render(
        _ segments: [SegmentData], names: [Int: String] = [:]
    ) -> String {
        var turns: [String] = []
        var currentSpeakerID: Int?
        var currentName = ""
        var currentStartTime: TimeInterval = 0
        var currentText = ""

        func flushTurn() {
            if !currentText.isEmpty {
                let timeText = TimeFormatting.formatPlaybackTime(currentStartTime)
                turns.append("[\(timeText)] \(currentName)\n\(currentText)")
            }
            currentSpeakerID = nil
            currentName = ""
            currentText = ""
        }

        for segment in segments {
            let trimmed = segment.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }

            let name = displayName(for: segment, names: names)
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

    // MARK: - Parse

    /// Parses free text — Biscotti's own rendered format or plain text from
    /// another app — into segment drafts (functional spec §4.2).
    ///
    /// A line matching `[<timestamp>] <name>` is a header: it sets the
    /// current speaker name and timestamp for every following line. Every
    /// non-header line becomes one segment carrying the current speaker and
    /// timestamp; line breaks make new segments, nothing is merged. When the
    /// name portion contains a colon, the text before the first colon is the
    /// speaker name and the text after is a content line for that speaker
    /// (`[0:23] Steve: hello`). Before any header is seen, the speaker is
    /// `Unknown Speaker` at `0`. Each distinct name gets a sequential
    /// speaker ID in order of first appearance, so the existing
    /// speaker-mapping UI works on imported transcripts.
    public static func parse(_ text: String) -> [TranscriptSegmentDraft] {
        // Built once per parse: `Regex` is not `Sendable`, so a `static let`
        // would not compile under Swift 6 strict concurrency — a local
        // binding has no such restriction. The inner groups are
        // non-capturing so the output stays a 2-tuple.
        let headerPattern = /\[((?:(?:\d{1,2}):)?(?:\d{1,3}):(?:\d{2}))\]\s*/

        var drafts: [TranscriptSegmentDraft] = []
        var speakerIDsByName: [String: Int] = [:]
        var currentName = unknownSpeakerName
        var currentTime: TimeInterval = 0

        func speakerID(for name: String) -> Int {
            if let existing = speakerIDsByName[name] {
                return existing
            }
            let assigned = speakerIDsByName.count
            speakerIDsByName[name] = assigned
            return assigned
        }

        for line in text.split(whereSeparator: \.isNewline) {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }

            if let header = parseHeader(trimmed, pattern: headerPattern) {
                currentName = header.name.isEmpty ? unknownSpeakerName : header.name
                currentTime = header.time
                if let inlineText = header.inlineText {
                    drafts.append(
                        TranscriptSegmentDraft(
                            speakerID: speakerID(for: currentName),
                            speakerLabel: currentName,
                            startTime: currentTime,
                            text: inlineText
                        )
                    )
                }
            } else {
                drafts.append(
                    TranscriptSegmentDraft(
                        speakerID: speakerID(for: currentName),
                        speakerLabel: currentName,
                        startTime: currentTime,
                        text: trimmed
                    )
                )
            }
        }
        return drafts
    }

    // MARK: - Internals

    private static let unknownSpeakerName = "Unknown Speaker"

    private struct ParsedHeader {
        let name: String
        let time: TimeInterval
        let inlineText: String?
    }

    /// Matches a `[M:SS]`, `[MM:SS]`, `[H:MM:SS]`, or `[HH:MM:SS]` prefix;
    /// whatever follows the closing bracket is the speaker name. Seconds
    /// are always two digits — that is what separates a header from
    /// ordinary prose that happens to contain brackets.
    private static func parseHeader(
        _ line: String,
        pattern: Regex<(Substring, Substring)>
    ) -> ParsedHeader? {
        guard let match = line.prefixMatch(of: pattern) else { return nil }

        let time = seconds(fromTimestamp: String(match.output.1))
        let trailing = line[match.range.upperBound...]
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard let colon = trailing.firstIndex(of: ":") else {
            return ParsedHeader(name: trailing, time: time, inlineText: nil)
        }
        // `[0:23] Steve: hello there` — several other apps emit that shape.
        let name = String(trailing[..<colon]).trimmingCharacters(in: .whitespaces)
        let inlineText = String(trailing[trailing.index(after: colon)...])
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return ParsedHeader(
            name: name,
            time: time,
            inlineText: inlineText.isEmpty ? nil : inlineText
        )
    }

    /// Two colon-separated parts are `M:SS`; three are `H:MM:SS`. The
    /// header pattern guarantees digits.
    private static func seconds(fromTimestamp timestamp: String) -> TimeInterval {
        let parts = timestamp.split(separator: ":").map { Int($0) ?? 0 }
        if parts.count == 3 {
            return TimeInterval(parts[0] * 3600 + parts[1] * 60 + parts[2])
        }
        return TimeInterval(parts[0] * 60 + parts[1])
    }
}
