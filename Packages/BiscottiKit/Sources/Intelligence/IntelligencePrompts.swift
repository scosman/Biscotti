import DataStore
import Foundation

/// Swift-constant prompt catalog for all Biscotti LLM features.
///
/// The analysis conversation uses structured XML sections to present meeting
/// context once, then asks successive questions (speaker identification, then
/// summary) across multiple turns. All functions are pure (no side effects)
/// and unit-tested.
public enum IntelligencePrompts {
    // MARK: - System

    /// System instruction for the multi-turn analysis conversation.
    public static let analysisSystem = """
    You will be given a meeting transcript and asked several questions about it \
    across multiple turns (for example, identifying the speakers, then writing a \
    summary). Answer each turn precisely, following exactly the format requested \
    in that turn.
    """

    // MARK: - Meeting Details Block

    /// Builds the `<meeting_details>` XML section from a meeting detail.
    /// Omits individual fields when absent/empty. Always includes at least the
    /// date line (date is non-optional on `MeetingDetailData`).
    public static func meetingDetailsBlock(
        _ detail: MeetingDetailData
    ) -> String {
        var lines: [String] = []

        if !detail.title.isEmpty {
            lines.append("Title: \(detail.title)")
        }

        lines.append(contentsOf: dateLines(detail))

        if let location = detail.calendar?.location, !location.isEmpty {
            lines.append("Location: \(location)")
        }

        if let platform = detail.calendar?.conferencePlatform, !platform.isEmpty {
            lines.append("Conference: \(platform)")
        }

        let inviteeLines = inviteeBlock(detail)
        if !inviteeLines.isEmpty {
            lines.append(inviteeLines)
        }

        if let notes = detail.calendar?.eventNotes, !notes.isEmpty {
            lines.append("Description:\n\(notes)")
        }

        guard !lines.isEmpty else { return "" }
        return "<meeting_details>\n\(lines.joined(separator: "\n"))\n</meeting_details>"
    }

    // MARK: - User Speaker Mapping Block

    /// Builds the `<user_speaker_person_mapping>` XML section from human-set
    /// speaker assignments. Returns `""` when the map is empty (caller omits
    /// the block entirely).
    public static func userSpeakerMappingBlock(
        _ human: [Int: PersonData]
    ) -> String {
        guard !human.isEmpty else { return "" }
        let sorted = human.sorted { $0.key < $1.key }
        let lines = sorted.map { speakerID, person in
            let email = person.email ?? ""
            return "\(speakerID) | \(person.name) | \(email)"
        }
        return "<user_speaker_person_mapping>\n\(lines.joined(separator: "\n"))\n</user_speaker_person_mapping>"
    }

    // MARK: - Task Instructions

    /// Instructions for the speaker-identification task appended to the first
    /// user turn when the speaker turn will run.
    public static let speakerTaskInstructions = """
    Match diarization speakers (Speaker 0, Speaker 1, ...) to real people using \
    evidence from the transcript (direct address like "Hi Daniel", \
    self-introductions, hand-offs) and the invitee list. Prefer matching to an \
    invitee so we capture their email. If a speaker cannot be confidently \
    identified, omit them.

    If a <user_speaker_person_mapping> section is provided above, those speakers \
    are already correctly assigned -- do not change them. Only assign the \
    currently unassigned speakers.

    Output format -- one line per newly identified speaker, nothing else:
    <speakerIndex> | <Full Name> | <email-or-blank>

    Example:
    0 | Daniel Lee | daniel@acme.com
    1 | Priya Patel |
    """

    /// Instructions for the summary task.
    public static let summaryTaskInstructions = """
    Produce a clear, well-organized markdown summary of the meeting covering the \
    key decisions, discussion topics, and outcomes. At the end, include a \
    "## Action Items" section as a checklist using `- [ ]` format, with owners \
    noted when clear from the transcript. You may reference the speaker names \
    identified earlier. Output markdown only -- no preamble, no commentary, and \
    do not invent content that is not in the transcript.
    """

    // MARK: - User Turn Builders

    /// First user turn when the speaker turn WILL run.
    /// Transcript uses Speaker-N labels (no resolved names).
    public static func analysisFirstUser(
        detail: MeetingDetailData,
        human: [Int: PersonData],
        transcriptSpeakerLabeled: String
    ) -> String {
        var parts: [String] = []

        let details = meetingDetailsBlock(detail)
        if !details.isEmpty { parts.append(details) }

        let mapping = userSpeakerMappingBlock(human)
        if !mapping.isEmpty { parts.append(mapping) }

        parts.append("<transcript>\n\(transcriptSpeakerLabeled)\n</transcript>")
        parts.append(speakerTaskInstructions)

        return parts.joined(separator: "\n\n")
    }

    /// First user turn when ONLY the summary runs (no speaker turn).
    /// Transcript uses resolved human names where available.
    public static func summaryOnlyFirstUser(
        detail: MeetingDetailData,
        transcriptNamed: String
    ) -> String {
        var parts: [String] = []

        let details = meetingDetailsBlock(detail)
        if !details.isEmpty { parts.append(details) }

        parts.append("<transcript>\n\(transcriptNamed)\n</transcript>")
        parts.append(summaryTaskInstructions)

        return parts.joined(separator: "\n\n")
    }

    /// Follow-up user turn for the summary task (transcript already in context).
    public static let summaryFollowUpUser = summaryTaskInstructions

    // MARK: - Title Task

    /// Instructions for the title generation task.
    public static let titleTaskInstructions = """
    Give this meeting a concise, specific title (a few words or a short phrase) \
    that captures the main topic discussed. Output a single bare line with no \
    quotes, no "Title:" label, and no trailing punctuation.
    """

    /// Follow-up user turn for the title task (transcript already in context).
    public static let titleFollowUpUser = titleTaskInstructions

    /// First user turn when ONLY the title runs (no prior turns).
    /// Transcript uses resolved human names where available.
    public static func titleOnlyFirstUser(
        detail: MeetingDetailData,
        transcriptNamed: String
    ) -> String {
        var parts: [String] = []

        let details = meetingDetailsBlock(detail)
        if !details.isEmpty { parts.append(details) }

        parts.append("<transcript>\n\(transcriptNamed)\n</transcript>")
        parts.append(titleTaskInstructions)

        return parts.joined(separator: "\n\n")
    }

    // MARK: - Private helpers

    private static func dateLines(
        _ detail: MeetingDetailData
    ) -> [String] {
        let startStr = Self.dateFormatter.string(from: detail.date)
        if let endDate = detail.endDate {
            let endStr = Self.dateFormatter.string(from: endDate)
            return ["Date: \(startStr) - \(endStr)"]
        }
        return ["Date: \(startStr)"]
    }

    private static func inviteeBlock(
        _ detail: MeetingDetailData
    ) -> String {
        guard let calendar = detail.calendar else { return "" }

        var invitees: [(name: String, email: String?)] = []

        // Organizer first
        if let organizer = calendar.organizer {
            invitees.append((name: organizer.name, email: organizer.email))
        }

        // Then attendees, deduped against organizer
        let organizerID = calendar.organizer?.id
        for attendee in calendar.attendees where attendee.id != organizerID {
            invitees.append((name: attendee.name, email: attendee.email))
        }

        guard !invitees.isEmpty else { return "" }

        let lines = invitees.map { invitee in
            if let email = invitee.email, !email.isEmpty {
                return "- \(invitee.name) <\(email)>"
            }
            return "- \(invitee.name)"
        }
        return "Invitees:\n\(lines.joined(separator: "\n"))"
    }

    /// Shared date formatter for meeting details.
    private static let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        formatter.locale = Locale(identifier: "en_US")
        return formatter
    }()
}
