import DataStore
import Foundation

/// Which names the AI may put on a speaker. Without this it
/// reached for anyone in Biscotti's people list ("Tyler Grant", a customer
/// from another meeting, kept landing on Nora). A guessed name is kept only
/// when the person is on this meeting's invite, is mentioned by name in the
/// transcript, or has been confirmed on a speaker before (by you or by
/// speaker naming). Otherwise the speaker stays "Speaker N".
struct SpeakerNameGuard {
    let invited: Set<String>
    let invitedEmails: Set<String>
    let confirmed: Set<String>
    let transcriptWords: Set<String>

    init(detail: MeetingDetailData, transcript: TranscriptData, confirmedNames: Set<String>) {
        var invitedPeople = detail.calendar?.attendees ?? []
        if let organizer = detail.calendar?.organizer { invitedPeople.append(organizer) }
        self.init(invited: invitedPeople, lines: transcript.segments.map(\.text), confirmedNames: confirmedNames)
    }

    init(invited invitedPeople: [PersonData], lines: [String], confirmedNames: Set<String>) {
        invited = Set(invitedPeople.map { Self.normalize($0.name) })
        invitedEmails = Set(invitedPeople.compactMap { $0.email?.lowercased() })
        confirmed = Set(confirmedNames.map(Self.normalize))
        transcriptWords = Set(
            lines.flatMap { $0.lowercased().split(whereSeparator: { !$0.isLetter }) }.map(String.init)
        )
    }

    func permits(name: String, email: String?) -> Bool {
        let key = Self.normalize(name)
        if invited.contains(key) || confirmed.contains(key) { return true }
        if let email = email?.lowercased(), invitedEmails.contains(email) { return true }
        // Mentioned: their first or last name is said in the meeting. Split
        // on non-letters, as the transcript is ("Anne-Marie O'Connor" ->
        // anne, marie, connor).
        let parts = key.split(whereSeparator: { !$0.isLetter }).map(String.init).filter { $0.count >= 3 }
        return parts.contains { transcriptWords.contains($0) }
    }

    /// "Brooks, Daniel" and "Daniel Brooks" compare equal; trailing
    /// " -" and case are ignored.
    static func normalize(_ name: String) -> String {
        var trimmed = name.trimmingCharacters(in: .whitespaces)
        while trimmed.hasSuffix("-") {
            trimmed = String(trimmed.dropLast()).trimmingCharacters(in: .whitespaces)
        }
        let parts = trimmed.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
        let ordered = parts.count == 2 ? "\(parts[1]) \(parts[0])" : trimmed
        return ordered.lowercased()
    }
}
