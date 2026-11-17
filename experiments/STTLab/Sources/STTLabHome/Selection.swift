import CryptoKit
import Foundation
import STTLabCore

// MARK: - Types

/// Duration bucket for meeting selection.
public enum Bucket: String, Codable, Sendable, Equatable {
    case short
    case long
}

/// A single entry in the selection file.
public struct SelectionEntry: Codable, Sendable, Equatable {
    public var meetingUUID: UUID
    public var title: String
    public var date: Date
    public var durationSeconds: Double
    public var speakerCount: Int
    public var wordCount: Int
    public var wordsPerMinute: Double
    public var language: String
    public var bucket: Bucket?
    public var appleLocale: String
    public var meetingID: String?

    public init(
        meetingUUID: UUID,
        title: String,
        date: Date,
        durationSeconds: Double,
        speakerCount: Int,
        wordCount: Int,
        wordsPerMinute: Double,
        language: String,
        bucket: Bucket? = nil,
        appleLocale: String = "en_US",
        meetingID: String? = nil
    ) {
        self.meetingUUID = meetingUUID
        self.title = title
        self.date = date
        self.durationSeconds = durationSeconds
        self.speakerCount = speakerCount
        self.wordCount = wordCount
        self.wordsPerMinute = wordsPerMinute
        self.language = language
        self.bucket = bucket
        self.appleLocale = appleLocale
        self.meetingID = meetingID
    }
}

/// The selection file written to the workspace.
public struct SelectionFile: Codable, Sendable, Equatable {
    public var schemaVersion: Int
    public var createdAt: Date
    public var notes: [String]
    public var meetings: [SelectionEntry]
    public var alternates: [SelectionEntry]
    public var confirmed: Bool
    public var confirmedAt: Date?
    public var confirmedHash: String?

    public init(
        schemaVersion: Int = SchemaVersions.selection,
        createdAt: Date = Date(),
        notes: [String] = [],
        meetings: [SelectionEntry] = [],
        alternates: [SelectionEntry] = [],
        confirmed: Bool = false,
        confirmedAt: Date? = nil,
        confirmedHash: String? = nil
    ) {
        self.schemaVersion = schemaVersion
        self.createdAt = createdAt
        self.notes = notes
        self.meetings = meetings
        self.alternates = alternates
        self.confirmed = confirmed
        self.confirmedAt = confirmedAt
        self.confirmedHash = confirmedHash
    }
}

// MARK: - Selector

/// Proposes a diverse set of meetings from the eligible candidates.
public enum Selector {
    /// Duration bands in minutes.
    private static let shortBand: ClosedRange<Double> = 25 ... 40
    private static let longBand: ClosedRange<Double> = 50 ... 75

    /// Propose a selection of meetings, filling short and long buckets with variety.
    /// - Parameters:
    ///   - candidates: All eligible meetings.
    ///   - short: Target count for the short bucket (default 5).
    ///   - long: Target count for the long bucket (default 5).
    /// - Returns: A `SelectionFile` with the proposal.
    public static func propose(
        _ candidates: [CandidateMeeting],
        short: Int = 5,
        long: Int = 5
    ) -> SelectionFile {
        let total = short + long
        var notes: [String] = []
        var chosen: [SelectionEntry] = []
        var usedUUIDs: Set<UUID> = []

        // Partition into bands.
        let shortCandidates = candidates.filter {
            let minutes = $0.durationSeconds / 60
            return shortBand.contains(minutes)
        }
        let longCandidates = candidates.filter {
            let minutes = $0.durationSeconds / 60
            return longBand.contains(minutes)
        }

        // Pick from each band.
        let shortPicked = pick(
            k: short,
            from: shortCandidates,
            bucket: .short,
            usedUUIDs: &usedUUIDs,
            notes: &notes,
            bandLabel: "short"
        )
        let longPicked = pick(
            k: long,
            from: longCandidates,
            bucket: .long,
            usedUUIDs: &usedUUIDs,
            notes: &notes,
            bandLabel: "long"
        )

        chosen.append(contentsOf: shortPicked)
        chosen.append(contentsOf: longPicked)

        // Shortfall fill: if either band is short, fill from remaining candidates
        // sorted by proximity to the band center.
        let shortShortfall = short - shortPicked.count
        let longShortfall = long - longPicked.count
        let shortfall = shortShortfall + longShortfall

        if shortfall > 0 {
            let remaining = candidates.filter { !usedUUIDs.contains($0.meetingUUID) }

            // Short fills: nearest to 30 min center.
            if shortShortfall > 0 {
                let sorted = remaining.sorted { a, b in
                    let da = abs(a.durationSeconds / 60 - 30)
                    let db = abs(b.durationSeconds / 60 - 30)
                    if da != db { return da < db }
                    return a.meetingUUID.uuidString < b.meetingUUID.uuidString
                }
                let fills = sorted.prefix(shortShortfall)
                for c in fills {
                    usedUUIDs.insert(c.meetingUUID)
                    chosen.append(makeEntry(c, bucket: nil))
                }
                if !fills.isEmpty {
                    notes.append(
                        "short bucket: \(shortCandidates.count) in band, "
                            + "\(fills.count) filled from nearest durations"
                    )
                }
            }

            // Long fills: nearest to 60 min center.
            if longShortfall > 0 {
                let remaining2 = candidates.filter { !usedUUIDs.contains($0.meetingUUID) }
                let sorted = remaining2.sorted { a, b in
                    let da = abs(a.durationSeconds / 60 - 60)
                    let db = abs(b.durationSeconds / 60 - 60)
                    if da != db { return da < db }
                    return a.meetingUUID.uuidString < b.meetingUUID.uuidString
                }
                let fills = sorted.prefix(longShortfall)
                for c in fills {
                    usedUUIDs.insert(c.meetingUUID)
                    chosen.append(makeEntry(c, bucket: nil))
                }
                if !fills.isEmpty {
                    notes.append(
                        "long bucket: \(longCandidates.count) in band, "
                            + "\(fills.count) filled from nearest durations"
                    )
                }
            }
        }

        // If total eligible < requested total, note it.
        if candidates.count < total {
            notes.append("only \(candidates.count) eligible meetings (requested \(total))")
        }

        // Sort: short bucket first, then long, then shortfall fills, then by date.
        chosen.sort { a, b in
            let orderA = bucketSortOrder(a.bucket)
            let orderB = bucketSortOrder(b.bucket)
            if orderA != orderB { return orderA < orderB }
            return a.date < b.date
        }

        // Add locale notes for non-English meetings.
        for entry in chosen where entry.language != "en" && !entry.language.isEmpty {
            let note = "\(entry.title): language is \(entry.language); set appleLocale before confirm"
            if !notes.contains(note) {
                notes.append(note)
            }
        }

        // Build alternates: next 10 by variety score against the chosen set.
        let alternates = buildAlternates(
            candidates: candidates,
            chosen: chosen,
            usedUUIDs: usedUUIDs,
            maxCount: 10
        )

        return SelectionFile(
            notes: notes,
            meetings: chosen,
            alternates: alternates
        )
    }

    // MARK: - Greedy max-min variety pick

    /// Pick k candidates from the given band using greedy max-min variety.
    ///
    /// The algorithm normalizes date and words-per-minute into [0,1], starts with
    /// the candidate whose wpm is closest to the band median, then greedily picks
    /// the candidate that maximizes the minimum distance to any already-chosen candidate.
    /// Ties are broken by meetingUUID string order.
    static func pick(
        k: Int,
        from band: [CandidateMeeting],
        bucket: Bucket,
        usedUUIDs: inout Set<UUID>,
        notes: inout [String],
        bandLabel: String
    ) -> [SelectionEntry] {
        let available = band.filter { !usedUUIDs.contains($0.meetingUUID) }
        guard !available.isEmpty else { return [] }

        let count = min(k, available.count)
        let features = normalizeFeatures(available)
        var picked: [Int] = []

        // Start: candidate closest to median wpm.
        let wpms = available.map(\.wordsPerMinute)
        let medianWpm = median(wpms)
        let startIdx = available.enumerated()
            .min { a, b in
                let da = abs(a.element.wordsPerMinute - medianWpm)
                let db = abs(b.element.wordsPerMinute - medianWpm)
                if da != db { return da < db }
                return a.element.meetingUUID.uuidString < b.element.meetingUUID.uuidString
            }!.offset
        picked.append(startIdx)

        // Greedy: pick the candidate that maximizes min-distance to any picked.
        while picked.count < count {
            var bestIdx = -1
            var bestMinDist = -1.0
            var bestUUID = ""

            for i in 0 ..< available.count where !picked.contains(i) {
                let minDist = picked.map { j in
                    distance(features[i], features[j],
                             speakerCountA: available[i].speakerCount,
                             speakerCountB: available[j].speakerCount)
                }.min() ?? 0

                if minDist > bestMinDist
                    || (minDist == bestMinDist && available[i].meetingUUID.uuidString < bestUUID)
                {
                    bestIdx = i
                    bestMinDist = minDist
                    bestUUID = available[i].meetingUUID.uuidString
                }
            }

            picked.append(bestIdx)
        }

        var result: [SelectionEntry] = []
        for idx in picked {
            let c = available[idx]
            usedUUIDs.insert(c.meetingUUID)
            result.append(makeEntry(c, bucket: bucket))
        }

        return result
    }

    // MARK: - Alternates

    private static func buildAlternates(
        candidates: [CandidateMeeting],
        chosen: [SelectionEntry],
        usedUUIDs: Set<UUID>,
        maxCount: Int
    ) -> [SelectionEntry] {
        let remaining = candidates.filter { !usedUUIDs.contains($0.meetingUUID) }
        guard !remaining.isEmpty, !chosen.isEmpty else {
            return remaining.prefix(maxCount).map { makeEntry($0, bucket: nil) }
        }

        // Score each remaining candidate by its min distance to the chosen set.
        let chosenFeatures = chosen.map { entry -> (x: Double, y: Double, speakers: Int) in
            (x: 0, y: entry.wordsPerMinute, speakers: entry.speakerCount)
        }

        let scored = remaining.map { c -> (candidate: CandidateMeeting, score: Double) in
            let minDist = chosenFeatures.map { chosen in
                abs(c.wordsPerMinute - chosen.y) / max(1, chosen.y)
                    + (c.speakerCount != chosen.speakers ? 0.5 : 0)
            }.min() ?? 0
            return (c, minDist)
        }
        .sorted { a, b in
            if a.score != b.score { return a.score > b.score }
            return a.candidate.meetingUUID.uuidString < b.candidate.meetingUUID.uuidString
        }

        return scored.prefix(maxCount).map { makeEntry($0.candidate, bucket: nil) }
    }

    // MARK: - Feature normalization

    private struct NormalizedFeature {
        let x: Double // date
        let y: Double // wpm
    }

    private static func normalizeFeatures(_ candidates: [CandidateMeeting]) -> [NormalizedFeature] {
        guard !candidates.isEmpty else { return [] }

        let dates = candidates.map(\.date.timeIntervalSinceReferenceDate)
        let wpms = candidates.map(\.wordsPerMinute)

        let minDate = dates.min()!
        let maxDate = dates.max()!
        let dateRange = max(maxDate - minDate, 1)

        let minWpm = wpms.min()!
        let maxWpm = wpms.max()!
        let wpmRange = max(maxWpm - minWpm, 1)

        return zip(dates, wpms).map { date, wpm in
            NormalizedFeature(
                x: (date - minDate) / dateRange,
                y: (wpm - minWpm) / wpmRange
            )
        }
    }

    private static func distance(
        _ a: NormalizedFeature,
        _ b: NormalizedFeature,
        speakerCountA: Int,
        speakerCountB: Int
    ) -> Double {
        abs(a.x - b.x) + abs(a.y - b.y) + (speakerCountA != speakerCountB ? 0.5 : 0)
    }

    private static func median(_ values: [Double]) -> Double {
        let sorted = values.sorted()
        let n = sorted.count
        if n == 0 { return 0 }
        if n % 2 == 0 {
            return (sorted[n / 2 - 1] + sorted[n / 2]) / 2
        }
        return sorted[n / 2]
    }

    private static func bucketSortOrder(_ bucket: Bucket?) -> Int {
        switch bucket {
        case .short: return 0
        case .long: return 1
        case nil: return 2
        }
    }

    // MARK: - Helpers

    static func makeEntry(_ c: CandidateMeeting, bucket: Bucket?) -> SelectionEntry {
        SelectionEntry(
            meetingUUID: c.meetingUUID,
            title: c.title,
            date: c.date,
            durationSeconds: c.durationSeconds,
            speakerCount: c.speakerCount,
            wordCount: c.wordCount,
            wordsPerMinute: c.wordsPerMinute,
            language: c.language,
            bucket: bucket,
            appleLocale: "en_US"
        )
    }
}
