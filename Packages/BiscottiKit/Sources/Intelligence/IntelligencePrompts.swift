/// Swift-constant prompt catalog for all Biscotti LLM features.
///
/// System prompts are static strings; user messages are builder functions that
/// inject transcript/invitee data. This is the reusable pattern future LLM
/// features follow.
public enum IntelligencePrompts {
    // MARK: - Summary

    /// System instruction for the summary generation call.
    public static let summarySystem = """
    You are a concise meeting-notes writer. Given a meeting transcript, produce \
    a clear, well-organized markdown summary covering the key decisions, \
    discussion topics, and outcomes. At the end, include a "## Action Items" \
    section as a checklist using `- [ ]` format, with owners noted when clear \
    from the transcript. Output markdown only -- no preamble, no commentary, \
    and do not invent content that is not in the transcript.
    """

    /// Builds the user message for the summary call.
    /// The transcript should already have speaker names resolved.
    public static func summaryUser(transcript: String) -> String {
        """
        Here is the meeting transcript:

        \(transcript)
        """
    }

    // MARK: - Speaker Identification

    /// System instruction for the speaker-identification call.
    public static let speakerSystem = """
    You are an assistant that identifies speakers in a meeting transcript. \
    Match diarization speakers (Speaker 0, Speaker 1, ...) to real people \
    using evidence from the transcript (direct address like "Hi Daniel", \
    self-introductions, hand-offs) and the provided invitee list. \
    Prefer matching to an invitee so we capture their email. \
    If a speaker cannot be confidently identified, omit them.

    Output format -- one line per identified speaker, nothing else:
    <speakerIndex> | <Full Name> | <email-or-blank>

    Example:
    0 | Daniel Lee | daniel@acme.com
    1 | Priya Patel |
    """

    /// Builds the user message for the speaker-identification call.
    /// - Parameters:
    ///   - transcript: Formatted transcript with "Speaker N" labels.
    ///   - invitees: Array of `(name, email)` pairs from the calendar, or empty.
    public static func speakerUser(
        transcript: String,
        invitees: [(name: String, email: String?)]
    ) -> String {
        let inviteeBlock: String
        if invitees.isEmpty {
            inviteeBlock = "No invitee list available."
        } else {
            let lines = invitees.map { invitee in
                if let email = invitee.email {
                    return "- \(invitee.name) <\(email)>"
                }
                return "- \(invitee.name)"
            }
            inviteeBlock = "Meeting invitees:\n\(lines.joined(separator: "\n"))"
        }

        return """
        \(inviteeBlock)

        Transcript:

        \(transcript)
        """
    }
}
