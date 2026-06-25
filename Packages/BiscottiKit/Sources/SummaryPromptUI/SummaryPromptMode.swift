/// The two contexts in which the summary prompt sheet is presented.
public enum SummaryPromptMode: Sendable {
    /// Editing the global default prompt (from Settings).
    case global

    /// Customizing a prompt for one meeting's re-summarization.
    ///
    /// - Parameters:
    ///   - reference: Title/date/duration of the target meeting.
    ///   - summaryWasEdited: Whether the meeting's current summary was
    ///     hand-edited (`editedSummary == true`), which drives the inline
    ///     replace warning.
    case perMeeting(reference: MeetingReference, summaryWasEdited: Bool)
}
