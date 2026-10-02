import DataStore
import Foundation

// MARK: - Metrics types

/// Accuracy per confidence level.
public struct LevelStats: Sendable, Codable, Equatable {
    public let total: Int
    public let correct: Int

    public init(total: Int, correct: Int) {
        self.total = total
        self.correct = correct
    }
}

/// One row in the DET sweep table.
public struct SweepRow: Sendable, Codable, Equatable {
    public let radius: Float
    public let falseMatchRate: Double
    public let missedMatchRate: Double

    public init(radius: Float, falseMatchRate: Double, missedMatchRate: Double) {
        self.radius = radius
        self.falseMatchRate = falseMatchRate
        self.missedMatchRate = missedMatchRate
    }
}

/// A pair of people that the matcher confuses.
public struct ConfusedPair: Sendable, Codable, Equatable {
    public let truth: String
    public let predicted: String
    public let count: Int

    public init(truth: String, predicted: String, count: Int) {
        self.truth = truth
        self.predicted = predicted
        self.count = count
    }
}

/// A confirmed voiceprint that is far from the person's other confirmed voiceprints.
public struct SuspectTag: Sendable, Codable, Equatable {
    public let person: String
    public let meetingTitle: String
    public let meetingDate: Date
    public let speakerID: Int
    public let distance: Float

    public init(person: String, meetingTitle: String, meetingDate: Date, speakerID: Int, distance: Float) {
        self.person = person
        self.meetingTitle = meetingTitle
        self.meetingDate = meetingDate
        self.speakerID = speakerID
        self.distance = distance
    }
}

/// Data coverage summary.
public struct Coverage: Sendable, Codable, Equatable {
    public let peopleWithConfirmed: Int
    public let atLeast3: Int
    public let atLeast5: Int
    public let speechUnder15s: Int
    public let speech15to60s: Int
    public let speech60to300s: Int
    public let speechOver300s: Int

    public init(
        peopleWithConfirmed: Int, atLeast3: Int, atLeast5: Int,
        speechUnder15s: Int, speech15to60s: Int, speech60to300s: Int, speechOver300s: Int
    ) {
        self.peopleWithConfirmed = peopleWithConfirmed
        self.atLeast3 = atLeast3
        self.atLeast5 = atLeast5
        self.speechUnder15s = speechUnder15s
        self.speech15to60s = speech15to60s
        self.speech60to300s = speech60to300s
        self.speechOver300s = speechOver300s
    }
}

/// Complete metrics from a leave-one-meeting-out evaluation.
public struct VoiceprintMetrics: Sendable, Codable, Equatable {
    public let kind: VoiceprintKind
    public let space: String
    public let trials: Int
    public let trialsWithoutHistory: Int
    public let top1Correct: Int
    public let byLevel: [MatchLevel: LevelStats]
    public let sweep: [SweepRow]
    public let equalErrorRadius: Float?
    /// Most-confused pairs, count descending, top 20.
    public let confusedPairs: [ConfusedPair]
    public let coverage: Coverage
    /// Voiceprints far from the person's mean, distance descending, top 20.
    public let suspectTags: [SuspectTag]

    public init(
        kind: VoiceprintKind, space: String, trials: Int, trialsWithoutHistory: Int,
        top1Correct: Int, byLevel: [MatchLevel: LevelStats], sweep: [SweepRow],
        equalErrorRadius: Float?, confusedPairs: [ConfusedPair],
        coverage: Coverage, suspectTags: [SuspectTag]
    ) {
        self.kind = kind
        self.space = space
        self.trials = trials
        self.trialsWithoutHistory = trialsWithoutHistory
        self.top1Correct = top1Correct
        self.byLevel = byLevel
        self.sweep = sweep
        self.equalErrorRadius = equalErrorRadius
        self.confusedPairs = confusedPairs
        self.coverage = coverage
        self.suspectTags = suspectTags
    }
}

// MARK: - Evaluator

/// Leave-one-meeting-out evaluator for voiceprint matching accuracy.
public struct VoiceprintEvaluator: Sendable {
    private let config: VoiceprintConfig
    private let sweepRadii: [Float]

    public init(
        config: VoiceprintConfig = .default,
        sweep: [Float]? = nil
    ) {
        self.config = config
        sweepRadii = sweep ?? stride(from: Float(0.20), through: Float(0.90), by: Float(0.05)).map(\.self)
    }

    /// Evaluates the corpus using leave-one-meeting-out cross-validation.
    public func evaluate(_ corpus: VoiceprintCorpusData) -> VoiceprintMetrics {
        let prepared = PreparedCorpus(corpus)
        let matcher = VoiceprintMatcher(config: config)
        let limits = config.thresholds(for: corpus.kind)

        var accumulator = TrialAccumulator()
        runTrials(prepared: prepared, matcher: matcher, corpus: corpus, accumulator: &accumulator)

        let byLevel = accumulator.buildLevelStats()
        let sweep = computeSweep(
            genuineDistances: accumulator.genuineDistances,
            impostorDistances: accumulator.impostorDistances
        )
        let eer = computeEER(sweep: sweep)
        let confusedPairs = accumulator.buildConfusedPairs()
        let coverage = computeCoverage(prepared: prepared)
        let suspects = computeSuspectTags(prepared: prepared, limits: limits, corpus: corpus)

        return VoiceprintMetrics(
            kind: corpus.kind,
            space: corpus.space,
            trials: accumulator.trials,
            trialsWithoutHistory: accumulator.trialsWithoutHistory,
            top1Correct: accumulator.top1Correct,
            byLevel: byLevel,
            sweep: sweep,
            equalErrorRadius: eer,
            confusedPairs: confusedPairs,
            coverage: coverage,
            suspectTags: suspects
        )
    }
}

// MARK: - Trial accumulator

/// Collects per-trial results to keep the evaluate method's complexity low.
private struct TrialAccumulator {
    var trials = 0
    var trialsWithoutHistory = 0
    var top1Correct = 0
    var levelTotals: [MatchLevel: Int] = [:]
    var levelCorrects: [MatchLevel: Int] = [:]
    var genuineDistances: [Float] = []
    var impostorDistances: [Float] = []

    /// Hashable key for confused-pair counting; avoids delimiter-in-name ambiguity.
    private struct ConfusedKey: Hashable {
        let truth: String
        let predicted: String
    }

    private var confusedCounts: [ConfusedKey: Int] = [:]

    mutating func recordTrial(speakerMatch: SpeakerMatch, truth: UUID, people: [UUID: PersonData]) {
        trials += 1
        let correct = speakerMatch.level != .none
            && speakerMatch.candidates.first?.personID == truth

        if correct { top1Correct += 1 }
        levelTotals[speakerMatch.level, default: 0] += 1
        levelCorrects[speakerMatch.level, default: 0] += correct ? 1 : 0

        if speakerMatch.level != .none, !correct,
           let predictedID = speakerMatch.candidates.first?.personID
        {
            let truthName = people[truth]?.name ?? truth.uuidString
            let predName = people[predictedID]?.name ?? predictedID.uuidString
            confusedCounts[ConfusedKey(truth: truthName, predicted: predName), default: 0] += 1
        }
    }

    func buildLevelStats() -> [MatchLevel: LevelStats] {
        var byLevel: [MatchLevel: LevelStats] = [:]
        for level in [MatchLevel.high, .medium, .low, .ambiguous, .none] {
            let total = levelTotals[level, default: 0]
            if total > 0 {
                byLevel[level] = LevelStats(total: total, correct: levelCorrects[level, default: 0])
            }
        }
        return byLevel
    }

    func buildConfusedPairs() -> [ConfusedPair] {
        Array(
            confusedCounts
                .map { key, count in
                    ConfusedPair(truth: key.truth, predicted: key.predicted, count: count)
                }
                .sorted { lhs, rhs in
                    if lhs.count != rhs.count { return lhs.count > rhs.count }
                    return lhs.truth < rhs.truth
                }
                .prefix(20)
        )
    }
}

// MARK: - Private helpers

private extension VoiceprintEvaluator {
    func runTrials(
        prepared: PreparedCorpus, matcher: VoiceprintMatcher,
        corpus: VoiceprintCorpusData, accumulator: inout TrialAccumulator
    ) {
        var meetingEntries: [UUID: [NormalizedEntry]] = [:]
        for entry in prepared.entries {
            meetingEntries[entry.meetingID, default: []].append(entry)
        }

        for (meetingID, entries) in meetingEntries {
            let rest = prepared.excluding(meetingID: meetingID)
            for entry in entries {
                guard let tag = entry.tag, tag.userSet else { continue }
                let truth = tag.personID

                if rest.history.perPerson[truth] == nil {
                    accumulator.trialsWithoutHistory += 1
                    continue
                }

                let result = matcher.match(
                    query: [entry.speakerID: entry.vector],
                    corpus: rest, invitees: .none
                )
                guard let speakerMatch = result[entry.speakerID] else { continue }

                accumulator.recordTrial(speakerMatch: speakerMatch, truth: truth, people: corpus.people)
                computeDETDistances(
                    queryVector: entry.vector, truth: truth,
                    rest: rest, genuineDistances: &accumulator.genuineDistances,
                    impostorDistances: &accumulator.impostorDistances
                )
            }
        }
    }

    func displayName(_ personID: UUID, in people: [UUID: PersonData]) -> String {
        people[personID]?.name ?? personID.uuidString
    }

    func computeDETDistances(
        queryVector: [Float], truth: UUID,
        rest: PreparedCorpus,
        genuineDistances: inout [Float],
        impostorDistances: inout [Float]
    ) {
        // Per-person distance: prefer the closest confirmed entry.
        // Fall back to the closest inferred entry only when no confirmed entries exist.
        // This matches VoiceprintMatcher.reportedDistance behaviour.
        var confirmedDist: [UUID: Float] = [:]
        var anyDist: [UUID: Float] = [:]

        for entry in rest.entries {
            guard let tag = entry.tag else { continue }
            let dist = VectorMath.distance(queryVector, entry.vector)

            if tag.userSet {
                if let existing = confirmedDist[tag.personID] {
                    if dist < existing { confirmedDist[tag.personID] = dist }
                } else {
                    confirmedDist[tag.personID] = dist
                }
            }

            if let existing = anyDist[tag.personID] {
                if dist < existing { anyDist[tag.personID] = dist }
            } else {
                anyDist[tag.personID] = dist
            }
        }

        // Effective distance: confirmed if available, else any
        let effectiveDistances: [UUID: Float] = anyDist.merging(confirmedDist) { _, confirmed in confirmed }

        if let genuineDist = effectiveDistances[truth] {
            genuineDistances.append(genuineDist)
        }

        for (personID, dist) in effectiveDistances where personID != truth {
            impostorDistances.append(dist)
        }
    }

    func computeSweep(
        genuineDistances: [Float],
        impostorDistances: [Float]
    ) -> [SweepRow] {
        guard !genuineDistances.isEmpty else { return [] }

        return sweepRadii.map { radius in
            let missed = genuineDistances.count(where: { $0 > radius })
            let missedRate = Double(missed) / Double(genuineDistances.count)

            let falseMatch = impostorDistances.count(where: { $0 <= radius })
            let falseRate = impostorDistances.isEmpty ? 0 :
                Double(falseMatch) / Double(impostorDistances.count)

            return SweepRow(radius: radius, falseMatchRate: falseRate, missedMatchRate: missedRate)
        }
    }

    func computeEER(sweep: [SweepRow]) -> Float? {
        guard !sweep.isEmpty else { return nil }

        var bestRow: SweepRow?
        var bestDiff = Double.greatestFiniteMagnitude

        for row in sweep {
            let diff = abs(row.falseMatchRate - row.missedMatchRate)
            if diff < bestDiff {
                bestDiff = diff
                bestRow = row
            }
        }

        return bestRow?.radius
    }

    func computeCoverage(prepared: PreparedCorpus) -> Coverage {
        let personHistory = prepared.history.perPerson

        let withConfirmed = personHistory.values.count(where: { $0.confirmedMeetings >= 1 })
        let atLeast3 = personHistory.values.count(where: { $0.confirmedMeetings >= 3 })
        let atLeast5 = personHistory.values.count(where: { $0.confirmedMeetings >= 5 })

        var under15 = 0
        var range15to60 = 0
        var range60to300 = 0
        var over300 = 0

        for entry in prepared.entries {
            guard entry.tag?.userSet == true else { continue }
            let dur = entry.speakingDuration
            switch dur {
            case ..<15: under15 += 1
            case 15 ..< 60: range15to60 += 1
            case 60 ..< 300: range60to300 += 1
            default: over300 += 1
            }
        }

        return Coverage(
            peopleWithConfirmed: withConfirmed,
            atLeast3: atLeast3,
            atLeast5: atLeast5,
            speechUnder15s: under15,
            speech15to60s: range15to60,
            speech60to300s: range60to300,
            speechOver300s: over300
        )
    }

    /// Distance from one entry to the normalized mean of the other entries' vectors.
    /// Returns nil if the mean cannot be normalized.
    func distanceToOthersMean(entry: NormalizedEntry, others: [NormalizedEntry]) -> Float? {
        guard !others.isEmpty else { return nil }
        let dim = entry.vector.count
        var mean = [Float](repeating: 0, count: dim)
        for other in others {
            for idx in 0 ..< dim {
                mean[idx] += other.vector[idx]
            }
        }
        let divisor = Float(others.count)
        for idx in 0 ..< dim {
            mean[idx] /= divisor
        }

        guard let normalizedMean = VectorMath.normalized(mean) else { return nil }
        return VectorMath.distance(entry.vector, normalizedMean)
    }

    func computeSuspectTags(
        prepared: PreparedCorpus,
        limits: KindThresholds,
        corpus: VoiceprintCorpusData
    ) -> [SuspectTag] {
        let acceptR = limits.acceptRadius

        // Group confirmed entries by person
        var personEntries: [UUID: [NormalizedEntry]] = [:]
        for entry in prepared.entries {
            guard let tag = entry.tag, tag.userSet else { continue }
            personEntries[tag.personID, default: []].append(entry)
        }

        var suspects: [SuspectTag] = []

        for (personID, entries) in personEntries {
            let meetingIDs = Set(entries.map(\.meetingID))
            guard meetingIDs.count >= 3 else { continue }

            for entry in entries {
                let others = entries.filter { $0.meetingID != entry.meetingID || $0.speakerID != entry.speakerID }
                guard let dist = distanceToOthersMean(entry: entry, others: others),
                      dist > acceptR
                else { continue }

                suspects.append(SuspectTag(
                    person: displayName(personID, in: corpus.people),
                    meetingTitle: entry.meetingTitle,
                    meetingDate: entry.meetingDate,
                    speakerID: entry.speakerID,
                    distance: dist
                ))
            }
        }

        suspects.sort { $0.distance > $1.distance }
        return Array(suspects.prefix(20))
    }
}
