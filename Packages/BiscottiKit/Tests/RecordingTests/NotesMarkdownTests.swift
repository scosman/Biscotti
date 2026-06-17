import Foundation
import Recording
import Testing

@Suite("NotesMarkdown — pure markdown generator")
struct NotesMarkdownTests {
    private let meetingID = UUID()

    // MARK: - generate

    @Test("generate with multiple notes produces oldest-first markdown")
    func generateMultipleNotes() {
        let notes = [
            MeetingNote(text: "First note", timestamp: 42.0),
            MeetingNote(text: "Second note", timestamp: 102.2)
        ]
        let result = NotesMarkdown.generate(notes: notes, meetingID: meetingID)
        let expected = """
        ### Notes During Meeting

        [0:42](biscotti://meeting/\(meetingID.uuidString)?time=42.0)
        First note

        [1:42](biscotti://meeting/\(meetingID.uuidString)?time=102.2)
        Second note
        """
        #expect(result == expected)
    }

    @Test("generate with empty notes returns nil")
    func generateEmptyReturnsNil() {
        let result = NotesMarkdown.generate(notes: [], meetingID: meetingID)
        #expect(result == nil)
    }

    @Test("generate with single note")
    func generateSingleNote() {
        let notes = [
            MeetingNote(text: "Only note", timestamp: 5.3)
        ]
        let result = NotesMarkdown.generate(notes: notes, meetingID: meetingID)
        let expected = """
        ### Notes During Meeting

        [0:05](biscotti://meeting/\(meetingID.uuidString)?time=5.3)
        Only note
        """
        #expect(result == expected)
    }

    @Test("generate preserves one decimal in seconds")
    func oneDecimalSeconds() throws {
        let notes = [
            MeetingNote(text: "Precise", timestamp: 123.456)
        ]
        let result = try #require(NotesMarkdown.generate(notes: notes, meetingID: meetingID))
        #expect(result.contains("time=123.5"))
    }

    @Test("generate with zero timestamp")
    func zeroTimestamp() throws {
        let notes = [
            MeetingNote(text: "Immediate", timestamp: 0)
        ]
        let result = try #require(NotesMarkdown.generate(notes: notes, meetingID: meetingID))
        #expect(result.contains("[0:00]"))
        #expect(result.contains("time=0.0"))
    }

    @Test("generate with hour-long timestamp uses h:mm:ss label")
    func hourTimestamp() throws {
        let notes = [
            MeetingNote(text: "Late note", timestamp: 3661.0)
        ]
        let result = try #require(NotesMarkdown.generate(notes: notes, meetingID: meetingID))
        #expect(result.contains("[1:01:01]"))
    }

    // MARK: - timeLabel

    @Test("timeLabel for under an hour")
    func timeLabelMinutesSeconds() {
        #expect(NotesMarkdown.timeLabel(0) == "0:00")
        #expect(NotesMarkdown.timeLabel(5) == "0:05")
        #expect(NotesMarkdown.timeLabel(65) == "1:05")
        #expect(NotesMarkdown.timeLabel(599) == "9:59")
    }

    @Test("timeLabel for an hour or more")
    func timeLabelHours() {
        #expect(NotesMarkdown.timeLabel(3600) == "1:00:00")
        #expect(NotesMarkdown.timeLabel(3661) == "1:01:01")
        #expect(NotesMarkdown.timeLabel(7200) == "2:00:00")
    }

    @Test("timeLabel for negative clamps to zero")
    func timeLabelNegative() {
        #expect(NotesMarkdown.timeLabel(-10) == "0:00")
    }

    // MARK: - merged

    @Test("merged with empty existing returns section as-is")
    func mergedEmptyExisting() {
        let section = "### Notes During Meeting\n\nSome note"
        let result = NotesMarkdown.merged(existing: "", section: section)
        #expect(result == section)
    }

    @Test("merged with non-empty existing appends after blank line")
    func mergedNonEmptyExisting() {
        let existing = "Some existing content"
        let section = "### Notes During Meeting\n\nSome note"
        let result = NotesMarkdown.merged(existing: existing, section: section)
        #expect(result == "Some existing content\n\n### Notes During Meeting\n\nSome note")
    }

    @Test("merged preserves existing content exactly")
    func mergedPreservesExisting() {
        let existing = "# My Notes\n\nImportant stuff"
        let section = "### Notes During Meeting"
        let result = NotesMarkdown.merged(existing: existing, section: section)
        #expect(result.hasPrefix("# My Notes\n\nImportant stuff"))
        #expect(result.hasSuffix("### Notes During Meeting"))
    }
}
