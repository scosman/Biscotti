import DataStore
import Foundation
import os

/// Names set by hand survive a re-transcription. Speaker
/// numbers change between runs, so each named speaker is matched to the new
/// speaker who covers the same stretches of the recording.
public struct PreviousNames: Sendable {
    /// Earlier versions with hand-set names, newest first.
    let versions: [(segments: [SegmentData], people: [Int: UUID])]
}

private let carryLogger = Logger(subsystem: "net.scosman.biscotti", category: "SpeakerNaming")

extension TranscriptionService {
    /// Hand-set names from every earlier version, newest first: a version
    /// that was re-transcribed before its names were carried still counts.
    func humanNamesOnPreferred(meetingID: UUID) async -> PreviousNames? {
        guard let detail = try? await store.meetingDetail(id: meetingID) else { return nil }
        var versions: [(segments: [SegmentData], people: [Int: UUID])] = []
        for version in detail.versions.sorted(by: { $0.createdAt > $1.createdAt }) {
            guard let human = try? await store.confirmedSpeakerMappings(for: version.id), !human.isEmpty,
                  let transcript = try? await store.transcript(id: version.id)
            else { continue }
            versions.append((transcript.segments, human.mapValues(\.id)))
        }
        return versions.isEmpty ? nil : PreviousNames(versions: versions)
    }

    func carryOverNames(_ previous: PreviousNames?, meetingID: UUID) async {
        guard let previous,
              let detail = try? await store.meetingDetail(id: meetingID),
              let transcript = detail.preferredTranscript
        else { return }
        var matches: [Int: UUID] = [:]
        for version in previous.versions {
            for (speakerID, personID) in Self.matchSpeakers(old: version.segments, oldPeople: version.people, new: transcript.segments)
                where matches[speakerID] == nil && !matches.values.contains(personID)
            {
                matches[speakerID] = personID
            }
        }
        for (speakerID, personID) in matches {
            do {
                try await store.setSpeakerAssignment(speakerID: speakerID, personID: personID, for: transcript.id)
            } catch {
                carryLogger.error("Couldn't carry a name over: \(error.localizedDescription, privacy: .public)")
            }
        }
        carryLogger.info("Carried \(matches.count, privacy: .public) hand-set name(s) to the new transcript")
    }

    /// For each named old speaker, the new speaker whose lines overlap theirs
    /// most, when at least half of the old speaker's time lands on that new
    /// speaker and at least half of that new speaker's time was theirs.
    /// Each new speaker takes at most one name.
    public nonisolated static func matchSpeakers(
        old: [SegmentData], oldPeople: [Int: UUID], new: [SegmentData]
    ) -> [Int: UUID] {
        let newTime = speakingTime(new)
        var candidates: [Candidate] = []
        for (oldID, personID) in oldPeople {
            let mine = old.filter { $0.speakerID == oldID }
            let total = mine.reduce(0) { $0 + ($1.endTime - $1.startTime) }
            guard total > 0 else { continue }
            for (newID, shared) in overlap(of: mine, with: new) {
                let ofOld = shared / total
                let ofNew = shared / max(newTime[newID] ?? shared, 0.001)
                if ofOld >= 0.5, ofNew >= 0.5 {
                    candidates.append(Candidate(newID: newID, personID: personID, score: ofOld + ofNew))
                }
            }
        }
        var result: [Int: UUID] = [:]
        var usedPeople: Set<UUID> = []
        for candidate in candidates.sorted(by: { $0.score > $1.score })
            where result[candidate.newID] == nil && !usedPeople.contains(candidate.personID)
        {
            result[candidate.newID] = candidate.personID
            usedPeople.insert(candidate.personID)
        }
        return result
    }

    private struct Candidate {
        var newID: Int
        var personID: UUID
        var score: Double
    }

    private nonisolated static func speakingTime(_ segments: [SegmentData]) -> [Int: Double] {
        var time: [Int: Double] = [:]
        for segment in segments {
            guard let id = segment.speakerID else { continue }
            time[id, default: 0] += segment.endTime - segment.startTime
        }
        return time
    }

    /// Seconds each new speaker shares with the given lines.
    private nonisolated static func overlap(of lines: [SegmentData], with new: [SegmentData]) -> [Int: Double] {
        var shared: [Int: Double] = [:]
        for segment in new {
            guard let newID = segment.speakerID else { continue }
            for line in lines {
                let seconds = min(segment.endTime, line.endTime) - max(segment.startTime, line.startTime)
                if seconds > 0 { shared[newID, default: 0] += seconds }
            }
        }
        return shared
    }
}
