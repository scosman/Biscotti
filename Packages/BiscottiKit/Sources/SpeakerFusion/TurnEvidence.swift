import Foundation

/// The voice names found by `nameClusters`, and the names
/// (the user's) that never count as a remote speaker.
struct ClusterNaming {
    let names: [Int: String]
    let excluded: Set<String>
}

/// Whole-meeting turn counting. See `NameEvidence`.
extension SpeakerFuser {
    /// Counts, for each named voice, the turns where the screen agreed.
    static func turnEvidence(
        _ words: [FusionWord],
        sources: [WordSource],
        timeline: ParticipantTimeline,
        naming: ClusterNaming,
        tuning: Tuning
    ) -> [String: NameEvidence] {
        guard !timeline.isEmpty, !naming.names.isEmpty else { return [:] }
        var evidence: [String: NameEvidence] = [:]
        for turn in turns(words, sources: sources, gap: tuning.turnGap)
            where turn.end - turn.start >= tuning.minimumTurn
        {
            guard let name = naming.names[turn.cluster] else { continue }
            var entry = evidence[name] ?? NameEvidence(turns: 0, agreeingTurns: 0, conflictingTurns: 0)
            entry.turns += 1
            let lower = turn.start - tuning.leadSlack
            let upper = turn.end + tuning.lagSlack
            let overlaps = timeline.overlaps(from: lower, until: upper, excluding: naming.excluded)
                .sorted { $0.value > $1.value }
            // Two people tied for the most highlight time say nothing either way.
            let tied = overlaps.count > 1 && overlaps[0].value - overlaps[1].value < 0.001
            if let top = overlaps.first, !tied,
               top.value >= (turn.end - turn.start) * tuning.turnCoverage
            {
                if top.key == name {
                    entry.agreeingTurns += 1
                } else {
                    entry.conflictingTurns += 1
                }
            }
            evidence[name] = entry
        }
        return evidence
    }

    struct Turn: Equatable {
        let cluster: Int
        let start: Double
        let end: Double
    }

    /// Unbroken runs of one voice in the remote audio.
    static func turns(_ words: [FusionWord], sources: [WordSource], gap: Double) -> [Turn] {
        var result: [Turn] = []
        var current: Turn?
        for index in words.indices {
            let word = words[index]
            guard sources[index] != .mic, let cluster = word.clusterID else {
                if let open = current { result.append(open) }
                current = nil
                continue
            }
            if let open = current, open.cluster == cluster, word.start - open.end <= gap {
                current = Turn(cluster: cluster, start: open.start, end: max(open.end, word.end))
            } else {
                if let open = current { result.append(open) }
                current = Turn(cluster: cluster, start: word.start, end: word.end)
            }
        }
        if let open = current { result.append(open) }
        return result
    }
}
