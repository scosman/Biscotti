import DataStore
import Foundation

/// Groups of Person records that are the same human (for example "Steve",
/// `steve@kiln.tech`, and a personal email). Used by the `metrics` tool so
/// alias records do not count as confusions or as false matches.
public enum PersonAliases {
    /// Resolves groups of names or emails to person IDs.
    ///
    /// A term matches every person whose name or email equals it
    /// (case-insensitive). Groups that resolve to fewer than two people are
    /// dropped. `unmatched` lists terms that match no person.
    public static func resolve(
        _ groups: [[String]], people: [UUID: PersonData]
    ) -> (groups: [[UUID]], unmatched: [String]) {
        // Sort for a deterministic canonical ID (the first in each group).
        let sortedPeople = people.values.sorted { $0.id.uuidString < $1.id.uuidString }
        var resolved: [[UUID]] = []
        var unmatched: [String] = []

        for group in groups {
            var ids: [UUID] = []
            for term in group {
                let key = term.trimmingCharacters(in: .whitespaces).lowercased()
                guard !key.isEmpty else { continue }
                let matches = sortedPeople.filter {
                    $0.name.lowercased() == key || $0.email?.lowercased() == key
                }
                if matches.isEmpty { unmatched.append(term) }
                for person in matches where !ids.contains(person.id) {
                    ids.append(person.id)
                }
            }
            if ids.count >= 2 { resolved.append(ids) }
        }
        return (resolved, unmatched)
    }
}

public extension VoiceprintCorpusData {
    /// Returns a copy where every tag in a group points to the group's first
    /// person ID, as if the Person records were merged.
    func mergingPeople(_ groups: [[UUID]]) -> VoiceprintCorpusData {
        var canonical: [UUID: UUID] = [:]
        for group in groups {
            guard let first = group.first else { continue }
            for id in group where canonical[id] == nil {
                canonical[id] = first
            }
        }
        guard !canonical.isEmpty else { return self }

        let merged = entries.map { entry -> VoiceprintData in
            guard let tag = entry.tag, let target = canonical[tag.personID] else { return entry }
            return VoiceprintData(
                meetingID: entry.meetingID, meetingTitle: entry.meetingTitle,
                meetingDate: entry.meetingDate, transcriptID: entry.transcriptID,
                speakerID: entry.speakerID, vector: entry.vector,
                speakingDuration: entry.speakingDuration,
                tag: SpeakerTagData(personID: target, userSet: tag.userSet)
            )
        }
        return VoiceprintCorpusData(kind: kind, space: space, entries: merged, people: people)
    }
}
