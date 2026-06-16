import Foundation

/// Pure generator for the "Notes During Meeting" markdown section.
///
/// Produces deep-link markdown from in-memory `MeetingNote`s. The output
/// is seeded into the meeting's `notes` field on stop and rendered by the
/// meeting-detail Notes tab's `MarkdownEditor`.
public enum NotesMarkdown {
    /// Returns the `### Notes During Meeting` section, or `nil` if `notes`
    /// is empty.
    ///
    /// Notes are emitted **oldest-first** (the storage order). Each note
    /// becomes a timestamp link followed by the note text on the next line,
    /// with a blank line separating entries.
    ///
    /// Link format:
    /// `[{m:ss}](biscotti://meeting/{id}?time={seconds})`
    /// where `{seconds}` is the raw elapsed with one decimal (e.g. `42.0`).
    public static func generate(
        notes: [MeetingNote], meetingID: UUID
    ) -> String? {
        guard !notes.isEmpty else { return nil }

        var lines = ["### Notes During Meeting"]
        let idString = meetingID.uuidString

        for note in notes {
            lines.append("")
            let label = timeLabel(note.timestamp)
            let seconds = String(format: "%.1f", note.timestamp)
            lines.append(
                "[\(label)](biscotti://meeting/\(idString)?time=\(seconds))"
            )
            lines.append(note.text)
        }

        return lines.joined(separator: "\n")
    }

    /// Combines an existing notes string with a generated section.
    ///
    /// If `existing` is empty, returns `section` as-is. Otherwise appends
    /// `section` after a blank line.
    public static func merged(
        existing: String, section: String
    ) -> String {
        if existing.isEmpty {
            return section
        }
        return existing + "\n\n" + section
    }

    /// Formats elapsed seconds as a display label: `m:ss` for under an
    /// hour, `h:mm:ss` for an hour or more.
    package static func timeLabel(_ seconds: TimeInterval) -> String {
        let total = max(0, Int(seconds))
        let hours = total / 3600
        let minutes = (total % 3600) / 60
        let secs = total % 60

        if hours > 0 {
            return String(format: "%d:%02d:%02d", hours, minutes, secs)
        }
        return String(format: "%d:%02d", minutes, secs)
    }
}
