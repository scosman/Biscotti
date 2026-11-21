import DataStore
import Foundation
import VoiceprintMatching

extension MeetingAnalyzer {
    /// High and medium voice matches, one speaker per person (the higher
    /// score wins).
    static func voiceAssignments(_ matches: [Int: SpeakerMatch]) -> [Int: (personID: UUID, provenance: SpeakerNameProvenance)] {
        var best: [UUID: (speakerID: Int, match: SpeakerMatch)] = [:]
        for (speakerID, match) in matches where match.level == .high || match.level == .medium {
            guard let candidate = match.candidates.first else { continue }
            if let existing = best[candidate.personID], let score = existing.match.candidates.first?.score,
               score >= candidate.score { continue }
            best[candidate.personID] = (speakerID, match)
        }
        var result: [Int: (personID: UUID, provenance: SpeakerNameProvenance)] = [:]
        for (personID, entry) in best {
            result[entry.speakerID] = (personID, pickProvenance(personID: personID, match: entry.match))
        }
        return result
    }

    /// The AI may name a voice with no voice evidence at all. Where there is
    /// weak or ambiguous evidence, only a pick that agrees with it counts.
    static func allowsAIPick(personID: UUID, match: SpeakerMatch?) -> Bool {
        guard let match else { return true }
        switch match.level {
        case .none: return true
        case .low, .ambiguous: return match.candidates.contains { $0.personID == personID }
        case .high, .medium: return false
        }
    }

    /// An AI pick the voice matcher agrees with is a voice
    /// match at the matcher's level; anything else is a guess.
    static func pickProvenance(personID: UUID, match: SpeakerMatch?) -> SpeakerNameProvenance {
        let guess = SpeakerNameProvenance(
            source: .guess, confidence: .low, detail: "Picked by AI from the transcript and invite"
        )
        guard let match, let best = match.candidates.first, best.personID == personID else { return guess }
        let confidence: SpeakerNameConfidence
        switch match.level {
        case .high: confidence = .high
        case .medium: confidence = .medium
        case .low: confidence = .low
        case .ambiguous, .none: return guess
        }
        let meetings = best.countedMeetings
        let detail = "Voice matches \(meetings) earlier meeting\(meetings == 1 ? "" : "s") (score \(String(format: "%.2f", best.score)))"
        return SpeakerNameProvenance(source: .voice, confidence: confidence, detail: detail)
    }
}
