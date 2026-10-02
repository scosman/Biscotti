import DataStore
import Foundation
import VoiceprintMatching

/// Renders the `<voiceprint_matches>` block for the LLM speaker turn.
enum VoiceprintReport {
    // swiftlint:disable:next function_parameter_count
    static func render(
        unassignedSpeakers: [Int],
        speakersWithVector: Set<Int>,
        matches: [Int: SpeakerMatch],
        history: HistoryStats,
        people: [UUID: PersonData],
        invitees: [PersonData],
        assignedPersonIDs: Set<UUID>
    ) -> String {
        guard history.meetingCount > 0 else { return "" }

        let display = DisplayContext(invitees: invitees)

        var lines: [String] = []

        let confirmed = history.confirmedMeetingCount
        lines.append(
            "Voiceprint history: \(history.meetingCount) earlier \(noun(history.meetingCount)), "
                + "\(confirmed) with names that the user confirmed."
        )
        lines.append("")

        for speakerID in unassignedSpeakers {
            lines.append(speakerLine(
                speakerID: speakerID,
                speakersWithVector: speakersWithVector,
                matches: matches, people: people,
                display: display
            ))
        }

        let inviteeLines = renderInviteeSection(
            invitees: invitees, matches: matches,
            history: history, assignedPersonIDs: assignedPersonIDs
        )
        lines.append(contentsOf: inviteeLines)

        return "<voiceprint_matches>\n\(lines.joined(separator: "\n"))\n</voiceprint_matches>"
    }

    // MARK: - Per-speaker rendering

    private struct DisplayContext {
        let hasInvitees: Bool
        let inviteeIDs: Set<UUID>

        init(invitees: [PersonData]) {
            hasInvitees = !invitees.isEmpty
            inviteeIDs = Set(invitees.map(\.id))
        }
    }

    private static func speakerLine(
        speakerID: Int,
        speakersWithVector: Set<Int>,
        matches: [Int: SpeakerMatch],
        people: [UUID: PersonData],
        display: DisplayContext
    ) -> String {
        guard speakersWithVector.contains(speakerID) else {
            return "Speaker \(speakerID): no voiceprint available for this speaker."
        }
        guard let match = matches[speakerID] else {
            return "Speaker \(speakerID): no match to any earlier speaker."
        }

        switch match.level {
        case .high, .medium, .low:
            return confidentLine(speakerID: speakerID, match: match, people: people, display: display)
        case .ambiguous:
            return ambiguousLine(speakerID: speakerID, match: match, people: people, display: display)
        case .none:
            if match.unnamedMeetingCount >= 2 {
                return "Speaker \(speakerID): voice matches an unnamed speaker from "
                    + "\(match.unnamedMeetingCount) earlier \(noun(match.unnamedMeetingCount))."
            }
            return "Speaker \(speakerID): no match to any earlier speaker."
        }
    }

    private static func confidentLine(
        speakerID: Int, match: SpeakerMatch,
        people: [UUID: PersonData], display: DisplayContext
    ) -> String {
        guard let candidate = match.candidates.first,
              let person = people[candidate.personID]
        else {
            return "Speaker \(speakerID): no match to any earlier speaker."
        }
        let personDisplay = displayPerson(person, display: display)
        let levelWord = match.level.rawValue.capitalized
        return "Speaker \(speakerID): \(levelWord) confidence match to \(personDisplay). "
            + "Heard in \(candidate.countedMeetings) earlier \(noun(candidate.countedMeetings)), "
            + "\(candidate.confirmedCountedMeetings) confirmed by the user."
    }

    private static func ambiguousLine(
        speakerID: Int, match: SpeakerMatch,
        people: [UUID: PersonData], display: DisplayContext
    ) -> String {
        let parts = match.candidates.map { candidate -> String in
            let person = people[candidate.personID]
            let personDisplay = person.map {
                displayPerson($0, display: display)
            } ?? "Unknown"
            return "\(personDisplay) (\(candidate.countedMeetings) \(noun(candidate.countedMeetings)), "
                + "\(candidate.confirmedCountedMeetings) confirmed by the user)"
        }
        return "Speaker \(speakerID): voice is close to more than one known person: \(naturalJoin(parts))."
    }

    // MARK: - Invitee section

    private static func renderInviteeSection(
        invitees: [PersonData],
        matches: [Int: SpeakerMatch],
        history: HistoryStats,
        assignedPersonIDs: Set<UUID>
    ) -> [String] {
        let eligible = invitees.filter { invitee in
            guard let email = invitee.email, !email.isEmpty else { return false }
            return !assignedPersonIDs.contains(invitee.id)
        }
        guard !eligible.isEmpty else { return [] }

        let inviteeMatches = buildInviteeMatches(invitees: eligible, matches: matches)

        var lines: [String] = ["", "Invitees with voiceprint history:"]

        for invitee in eligible {
            guard let email = invitee.email else { continue }
            let personHist = history.perPerson[invitee.id]

            guard let hist = personHist, hist.meetings > 0 else {
                lines.append("\(email): no voiceprint history.")
                continue
            }

            let info = inviteeMatches[invitee.id]
            lines.append(inviteeLine(email: email, hist: hist, info: info))
        }

        return lines
    }

    private static func inviteeLine(
        email: String, hist: PersonHistory, info: InviteeMatchInfo?
    ) -> String {
        let bestSpeakers = info?.bestMatchSpeakers ?? []
        let ambiguousSpeakers = info?.ambiguousMatchSpeakers ?? []
        let meetingDesc = "\(hist.meetings) earlier \(noun(hist.meetings))"

        if !bestSpeakers.isEmpty {
            let joined = naturalJoin(bestSpeakers.map { "Speaker \($0)" })
            return "\(email): \(meetingDesc). Matches \(joined)."
        } else if !ambiguousSpeakers.isEmpty {
            let joined = naturalJoin(ambiguousSpeakers.map { "Speaker \($0)" })
            return "\(email): \(meetingDesc). Possible match to \(joined)."
        }
        return "\(email): \(meetingDesc). Matches no speaker in this recording."
    }

    // MARK: - Private helpers

    private static func noun(_ count: Int) -> String {
        count == 1 ? "meeting" : "meetings"
    }

    private static func displayPerson(
        _ person: PersonData, display: DisplayContext
    ) -> String {
        var result = if let email = person.email, !email.isEmpty {
            "\(person.name) <\(email)>"
        } else {
            "\(person.name) (no email)"
        }
        if display.hasInvitees, !display.inviteeIDs.contains(person.id) {
            result += " (not invited)"
        }
        return result
    }

    private static func naturalJoin(_ items: [String]) -> String {
        switch items.count {
        case 0: return ""
        case 1: return items[0]
        case 2: return "\(items[0]) and \(items[1])"
        default:
            let allButLast = items.dropLast().joined(separator: ", ")
            return "\(allButLast), and \(items[items.count - 1])"
        }
    }

    private struct InviteeMatchInfo {
        var bestMatchSpeakers: [Int] = []
        var ambiguousMatchSpeakers: [Int] = []
    }

    private static func buildInviteeMatches(
        invitees: [PersonData],
        matches: [Int: SpeakerMatch]
    ) -> [UUID: InviteeMatchInfo] {
        let inviteeIDs = Set(invitees.map(\.id))
        var result: [UUID: InviteeMatchInfo] = [:]
        for invitee in invitees {
            result[invitee.id] = InviteeMatchInfo()
        }

        for (speakerID, match) in matches.sorted(by: { $0.key < $1.key }) {
            switch match.level {
            case .high, .medium, .low:
                if let topCandidate = match.candidates.first,
                   inviteeIDs.contains(topCandidate.personID)
                {
                    result[topCandidate.personID]?.bestMatchSpeakers.append(speakerID)
                }
            case .ambiguous:
                for candidate in match.candidates where inviteeIDs.contains(candidate.personID) {
                    result[candidate.personID]?.ambiguousMatchSpeakers.append(speakerID)
                }
            case .none:
                break
            }
        }

        return result
    }
}
