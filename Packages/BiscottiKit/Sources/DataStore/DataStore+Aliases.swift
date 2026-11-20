import Foundation
import SwiftData

// MARK: - Person aliases

/// The same person often shows up under different names: "Lopez, Maria
/// (AGENCY)" in Teams, "Maria Reyes" in an old invite, "Maria M" in Zoom.
/// Aliases tie those names to one person, so naming lands on that person
/// (and adds to their voiceprint) instead of creating a second one.
public enum PersonAlias {
    /// "Lopez, Maria (AGENCY)" -> "maria lopez".
    public static func key(_ name: String) -> String {
        let stripped = name.replacingOccurrences(of: #"\s*\([^)]*\)"#, with: "", options: .regularExpression)
        let parts = stripped.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        let ordered = parts.count == 2 ? "\(parts[1]) \(parts[0])" : stripped
        return ordered.lowercased().split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }

    /// True when two names have a word of 2+ letters in common, so they could
    /// be the same person under another name ("Lopez, Maria" and "Maria
    /// Reyes"), not two different people.
    public static func sharesAName(_ lhs: String, _ rhs: String) -> Bool {
        func words(_ name: String) -> Set<String> {
            Set(key(name).split(whereSeparator: { !$0.isLetter }).map(String.init).filter { $0.count >= 2 })
        }
        return !words(lhs).isDisjoint(with: words(rhs))
    }
}

public extension DataStore {
    /// Records that `alias` is another name for the person.
    func addAlias(_ alias: String, for personID: UUID) {
        let key = PersonAlias.key(alias)
        guard !key.isEmpty else { return }
        aliases[key] = personID
        saveAliases()
    }

    /// Other names recorded for a person.
    func aliases(for personID: UUID) -> [String] {
        aliases.filter { $0.value == personID }.map(\.key).sorted()
    }

    /// The person a name was taught to belong to, if any.
    func personWithAlias(_ name: String) throws -> UUID? {
        guard let personID = aliases[PersonAlias.key(name)], try fetchPerson(id: personID) != nil else { return nil }
        return personID
    }

    /// The person a name belongs to by alias or by the same name in another
    /// order, if any. A taught alias wins; a name-order match counts only if
    /// exactly one person matches (two "Sam Carter"s are not one person).
    func personMatchingAlias(_ name: String) throws -> UUID? {
        let key = PersonAlias.key(name)
        if let taught = try personWithAlias(name) {
            return taught
        }
        let matches = try context.fetch(FetchDescriptor<Person>()).filter { PersonAlias.key($0.name) == key }
        return matches.count == 1 ? matches[0].id : nil
    }

    /// Adds people seen in the meeting (on its participant tiles) to its
    /// participants, keeping the invite's. Returns how many were new.
    @discardableResult
    func addParticipants(_ personIDs: [UUID], to meetingID: UUID) throws -> Int {
        guard let meeting = try meeting(id: meetingID) else { throw DataStoreError.notFound(meetingID) }
        let existing = Set(meeting.participants.map(\.id))
        var added = 0
        for personID in personIDs where !existing.contains(personID) {
            guard let person = try fetchPerson(id: personID) else { continue }
            meeting.participants.append(person)
            added += 1
        }
        if added > 0 { try save() }
        return added
    }

    /// Removes people that were never people ("Live Captions", a caption
    /// line or an audio device read as a name). Automatic speaker names
    /// pointing at them are cleared and they leave any attendee list;
    /// hand-set ones are left alone, and so is any person still used by one
    /// or organizing a meeting. Returns how many people were removed.
    @discardableResult
    func removeJunkPeople(where isJunk: @Sendable (String) -> Bool) throws -> Int {
        let people = try context.fetch(FetchDescriptor<Person>()).filter { isJunk($0.name) }
        guard !people.isEmpty else { return 0 }
        let junkIDs = Set(people.map(\.id))
        var stillUsed: Set<UUID> = []
        for record in try context.fetch(FetchDescriptor<TranscriptRecord>()) {
            var assignments = record.speakerAssignments
            var changed = false
            for (speakerID, entry) in assignments where junkIDs.contains(entry.personID) {
                if entry.effectiveProvenance.source == .confirmed {
                    stillUsed.insert(entry.personID)
                } else {
                    assignments.removeValue(forKey: speakerID)
                    changed = true
                }
            }
            if changed { record.speakerAssignments = assignments }
        }
        var removed = 0
        for person in people where !stillUsed.contains(person.id) && person.organizedMeetings.isEmpty {
            for meeting in person.meetings {
                meeting.participants.removeAll { $0.id == person.id }
            }
            context.delete(person)
            removed += 1
        }
        try save()
        return removed
    }
}

extension DataStore {
    static func loadAliases(from url: URL?) -> [String: UUID] {
        guard let url, let data = try? Data(contentsOf: url),
              let raw = try? JSONDecoder().decode([String: String].self, from: data) else { return [:] }
        return raw.compactMapValues(UUID.init(uuidString:))
    }

    func saveAliases() {
        guard let aliasFile else { return }
        let raw = aliases.mapValues(\.uuidString)
        if let data = try? JSONEncoder().encode(raw) {
            try? data.write(to: aliasFile, options: .atomic)
        }
    }
}
