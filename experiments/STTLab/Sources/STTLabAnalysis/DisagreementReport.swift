import CryptoKit
import Foundation

// MARK: - Disagreement report (written by `analyze prep`, read by LLM judge)

/// The JSON file written per meeting by `analyze prep`.
public struct DisagreementReportFile: Codable, Sendable {
    public var schemaVersion: Int
    public var meetingId: String
    public var reportFingerprint: String
    public var hasReference: Bool
    public var durationSeconds: Double
    public var engines: EngineDescriptions
    public var instructions: String
    public var decisionFile: DecisionFileExample
    public var disagreements: [DisagreementEntry]

    enum CodingKeys: String, CodingKey {
        case schemaVersion = "schema_version"
        case meetingId = "meeting_id"
        case reportFingerprint = "report_fingerprint"
        case hasReference = "has_reference"
        case durationSeconds = "duration_seconds"
        case engines, instructions
        case decisionFile = "decision_file"
        case disagreements
    }

    public init(meetingId: String, hasReference: Bool, durationSeconds: Double,
                disagreements: [DisagreementEntry]) {
        self.schemaVersion = 1
        self.meetingId = meetingId
        self.hasReference = hasReference
        self.durationSeconds = durationSeconds
        self.engines = EngineDescriptions()
        self.instructions = Self.defaultInstructions
        self.disagreements = disagreements
        self.reportFingerprint = Self.computeFingerprint(disagreements)
        self.decisionFile = DecisionFileExample(
            fileName: "disagreement_decision.json",
            example: DisagreementDecisionFile(
                meetingId: meetingId,
                reportFingerprint: "COPY_FROM_REPORT",
                decisions: disagreements.prefix(1).map { entry in
                    DecisionEntry(id: entry.id, decision: "apple_wins",
                                  severity: "low", note: "example")
                }
            )
        )
    }

    /// SHA-256 hex digest of the canonical JSON of the disagreements array.
    public static func computeFingerprint(_ entries: [DisagreementEntry]) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        guard let data = try? encoder.encode(entries) else { return "error" }
        let digest = SHA256.hash(data: data)
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    // swiftlint:disable:next line_length
    static let defaultInstructions = """
    You are judging transcription quality for Biscotti, a meeting recorder whose transcripts \
    feed summaries, search, and action items. For each disagreement region, three transcript \
    excerpts are shown: Apple (on-device candidate), Whisper (on-device current production), \
    and Reference (a strong cloud model — good but not ground truth). Decide which local \
    engine is better for that region. Decision values: "apple_wins" (Apple is clearly better), \
    "whisper_wins" (Whisper is clearly better), "both_acceptable" (e.g. "they are" vs \
    "they're", "five" vs "5", filler-word differences, punctuation-only, equivalent meaning), \
    "unknown" (cannot tell). Severity of the LOSING engine's mistake: "low" (minor, unlikely \
    to affect downstream use), "med" (noticeable, could affect search or summary), "high" \
    (changes meaning, drops content, or introduces hallucinated text). For "both_acceptable" \
    use "low". An empty string means that engine wrote nothing there — this is a deletion, or \
    if the other engine repeats short phrases like "Thank you." over silence, likely a \
    hallucination by the other engine. Copy "report_fingerprint" into the decision file. Give \
    a decision for every id. An optional short "note" may explain your reasoning.
    """
}

/// Engine description block.
public struct EngineDescriptions: Codable, Sendable {
    public var apple: String
    public var whisper: String
    public var reference: String

    public init(
        apple: String = "Apple SpeechTranscriber (on-device, candidate)",
        whisper: String = "WhisperKit large-v3-turbo (on-device, current production)",
        reference: String = "MAI-Transcribe 2 (cloud SOTA; strong but not ground truth)"
    ) {
        self.apple = apple
        self.whisper = whisper
        self.reference = reference
    }
}

/// Example of the decision file embedded in the report.
public struct DecisionFileExample: Codable, Sendable {
    public var fileName: String
    public var example: DisagreementDecisionFile

    enum CodingKeys: String, CodingKey {
        case fileName = "file_name"
        case example
    }

    public init(fileName: String, example: DisagreementDecisionFile) {
        self.fileName = fileName
        self.example = example
    }
}

/// A single disagreement entry in the report.
public struct DisagreementEntry: Codable, Sendable, Equatable {
    public var id: String
    public var startSeconds: Double
    public var endSeconds: Double
    public var time: String
    public var apple: String
    public var whisper: String
    public var reference: String?
    public var contextBefore: String
    public var contextAfter: String

    enum CodingKeys: String, CodingKey {
        case id
        case startSeconds = "start_seconds"
        case endSeconds = "end_seconds"
        case time, apple, whisper, reference
        case contextBefore = "context_before"
        case contextAfter = "context_after"
    }

    public init(id: String, startSeconds: Double, endSeconds: Double, time: String,
                apple: String, whisper: String, reference: String?,
                contextBefore: String, contextAfter: String) {
        self.id = id
        self.startSeconds = startSeconds
        self.endSeconds = endSeconds
        self.time = time
        self.apple = apple
        self.whisper = whisper
        self.reference = reference
        self.contextBefore = contextBefore
        self.contextAfter = contextAfter
    }

    /// Write `"reference": null` (not an omitted key) when there is no reference,
    /// so an LLM reader sees the field is absent on purpose.
    public func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(startSeconds, forKey: .startSeconds)
        try c.encode(endSeconds, forKey: .endSeconds)
        try c.encode(time, forKey: .time)
        try c.encode(apple, forKey: .apple)
        try c.encode(whisper, forKey: .whisper)
        if let reference {
            try c.encode(reference, forKey: .reference)
        } else {
            try c.encodeNil(forKey: .reference)
        }
        try c.encode(contextBefore, forKey: .contextBefore)
        try c.encode(contextAfter, forKey: .contextAfter)
    }
}

// MARK: - Disagreement decision (written by LLM judge, read by `analyze final`)

/// The JSON file written by the LLM judge per meeting.
public struct DisagreementDecisionFile: Codable, Sendable {
    public var schemaVersion: Int
    public var meetingId: String
    public var reportFingerprint: String
    public var decisions: [DecisionEntry]

    enum CodingKeys: String, CodingKey {
        case schemaVersion = "schema_version"
        case meetingId = "meeting_id"
        case reportFingerprint = "report_fingerprint"
        case decisions
    }

    public init(meetingId: String, reportFingerprint: String,
                decisions: [DecisionEntry]) {
        self.schemaVersion = 1
        self.meetingId = meetingId
        self.reportFingerprint = reportFingerprint
        self.decisions = decisions
    }
}

/// A single decision from the LLM judge.
public struct DecisionEntry: Codable, Sendable {
    public var id: String
    public var decision: String
    public var severity: String
    public var note: String?

    public init(id: String, decision: String, severity: String, note: String? = nil) {
        self.id = id
        self.decision = decision
        self.severity = severity
        self.note = note
    }
}

// MARK: - Parsed decision (normalized from raw LLM output)

/// Normalized decision value.
public enum LLMDecisionValue: String, Codable, Sendable, CaseIterable {
    case appleWins = "apple_wins"
    case whisperWins = "whisper_wins"
    case bothAcceptable = "both_acceptable"
    case unknown
    case undecided
    case invalid
}

/// Normalized severity.
public enum LLMSeverity: String, Codable, Sendable, CaseIterable {
    case low
    case med
    case high
    case unknown
}

/// A fully parsed and normalized decision.
public struct ParsedDecision: Codable, Sendable {
    public var id: String
    public var decision: LLMDecisionValue
    public var severity: LLMSeverity
    public var note: String?
    public var appleText: String
    public var whisperText: String
    public var referenceText: String?
    public var time: String
    public var startSeconds: Double
    public var meetingID: String

    public init(id: String, decision: LLMDecisionValue, severity: LLMSeverity,
                note: String? = nil, appleText: String = "", whisperText: String = "",
                referenceText: String? = nil, time: String = "", startSeconds: Double = 0,
                meetingID: String = "") {
        self.id = id
        self.decision = decision
        self.severity = severity
        self.note = note
        self.appleText = appleText
        self.whisperText = whisperText
        self.referenceText = referenceText
        self.time = time
        self.startSeconds = startSeconds
        self.meetingID = meetingID
    }
}

/// Result of parsing a meeting's decisions.
public struct MeetingDecisionResult: Sendable {
    public var meetingID: String
    public var judged: Bool
    public var fingerprintMatch: Bool
    public var decisions: [ParsedDecision]
    public var warnings: [String]

    public init(meetingID: String, judged: Bool, fingerprintMatch: Bool,
                decisions: [ParsedDecision], warnings: [String]) {
        self.meetingID = meetingID
        self.judged = judged
        self.fingerprintMatch = fingerprintMatch
        self.decisions = decisions
        self.warnings = warnings
    }
}

/// Parse a decision file tolerantly, matching decisions to the report entries.
public enum DecisionParser {

    /// Parse a decision file's raw JSON data, matching it against report entries.
    ///
    /// Tolerant of LLM output: accepts extra fields, case-insensitive decision/severity,
    /// `medium` as `med`, invalid values counted as `invalid` with a warning,
    /// unknown IDs warned and ignored, missing IDs counted as `undecided`,
    /// fingerprint mismatch warned but decisions still used.
    public static func parse(
        decisionData: Data?,
        reportEntries: [DisagreementEntry],
        reportFingerprint: String,
        meetingID: String
    ) -> MeetingDecisionResult {
        guard let data = decisionData else {
            // No decision file: all entries are undecided.
            let decisions = reportEntries.map { entry in
                ParsedDecision(
                    id: entry.id, decision: .undecided, severity: .unknown,
                    appleText: entry.apple, whisperText: entry.whisper,
                    referenceText: entry.reference, time: entry.time,
                    startSeconds: entry.startSeconds, meetingID: meetingID
                )
            }
            return MeetingDecisionResult(
                meetingID: meetingID, judged: false,
                fingerprintMatch: true, decisions: decisions, warnings: []
            )
        }

        var warnings: [String] = []
        var fingerprintMatch = true

        // Decode with tolerance for extra fields.
        let decoder = JSONDecoder()
        guard let file = try? decoder.decode(DisagreementDecisionFile.self, from: data) else {
            warnings.append("\(meetingID): decision file failed to parse — treating as not judged")
            let decisions = reportEntries.map { entry in
                ParsedDecision(
                    id: entry.id, decision: .undecided, severity: .unknown,
                    appleText: entry.apple, whisperText: entry.whisper,
                    referenceText: entry.reference, time: entry.time,
                    startSeconds: entry.startSeconds, meetingID: meetingID
                )
            }
            return MeetingDecisionResult(
                meetingID: meetingID, judged: false,
                fingerprintMatch: true, decisions: decisions, warnings: warnings
            )
        }

        // Check fingerprint.
        if file.reportFingerprint != reportFingerprint {
            fingerprintMatch = false
            warnings.append("\(meetingID): decision fingerprint does not match report — decisions may be stale")
        }

        // Build lookup by ID.
        let entryLookup = Dictionary(uniqueKeysWithValues: reportEntries.map { ($0.id, $0) })
        var decisionLookup: [String: DecisionEntry] = [:]
        for d in file.decisions {
            if entryLookup[d.id] == nil {
                warnings.append("\(meetingID): unknown decision ID \(d.id) — ignored")
            } else {
                decisionLookup[d.id] = d
            }
        }

        // Build parsed decisions for each report entry.
        var parsed: [ParsedDecision] = []
        for entry in reportEntries {
            guard let raw = decisionLookup[entry.id] else {
                // Missing decision for this ID.
                parsed.append(ParsedDecision(
                    id: entry.id, decision: .undecided, severity: .unknown,
                    appleText: entry.apple, whisperText: entry.whisper,
                    referenceText: entry.reference, time: entry.time,
                    startSeconds: entry.startSeconds, meetingID: meetingID
                ))
                continue
            }

            let decision = parseDecisionValue(raw.decision, id: raw.id,
                                              meetingID: meetingID, warnings: &warnings)
            let severity = parseSeverity(raw.severity, id: raw.id,
                                         meetingID: meetingID, warnings: &warnings)

            parsed.append(ParsedDecision(
                id: entry.id, decision: decision, severity: severity,
                note: raw.note,
                appleText: entry.apple, whisperText: entry.whisper,
                referenceText: entry.reference, time: entry.time,
                startSeconds: entry.startSeconds, meetingID: meetingID
            ))
        }

        return MeetingDecisionResult(
            meetingID: meetingID, judged: true,
            fingerprintMatch: fingerprintMatch,
            decisions: parsed, warnings: warnings
        )
    }

    /// Parse a decision string tolerantly (case-insensitive).
    static func parseDecisionValue(_ raw: String, id: String, meetingID: String,
                                   warnings: inout [String]) -> LLMDecisionValue {
        let normalized = raw.lowercased().trimmingCharacters(in: .whitespaces)
        switch normalized {
        case "apple_wins": return .appleWins
        case "whisper_wins": return .whisperWins
        case "both_acceptable", "both_ok": return .bothAcceptable
        case "unknown": return .unknown
        default:
            warnings.append("\(meetingID)/\(id): invalid decision '\(raw)' — counted as invalid")
            return .invalid
        }
    }

    /// Parse a severity string tolerantly (case-insensitive, `medium` -> `med`).
    static func parseSeverity(_ raw: String, id: String, meetingID: String,
                              warnings: inout [String]) -> LLMSeverity {
        let normalized = raw.lowercased().trimmingCharacters(in: .whitespaces)
        switch normalized {
        case "low": return .low
        case "med", "medium": return .med
        case "high": return .high
        default:
            warnings.append("\(meetingID)/\(id): invalid severity '\(raw)' — defaulting to unknown")
            return .unknown
        }
    }
}

// MARK: - Building disagreement entries from TieBreak regions

public enum DisagreementReportBuilder {

    /// Build DisagreementEntry list from TieBreak regions for one meeting.
    ///
    /// The entries include all regions (not just the sample), with deterministic
    /// IDs in time order.
    public static func buildEntries(
        regions: [DisagreementRegion],
        meetingID: String,
        hasReference: Bool,
        referenceWords: [EngineWord]?,
        appleWords: [EngineWord]?,
        whisperWords: [EngineWord]?
    ) -> [DisagreementEntry] {
        // Sort regions by time (earliest start across all engines).
        let sorted = regions.sorted { a, b in
            let aStart = a.regionTimeStart ?? a.whisperTimeStart ?? a.appleTimeStart ?? 0
            let bStart = b.regionTimeStart ?? b.whisperTimeStart ?? b.appleTimeStart ?? 0
            return aStart < bStart
        }

        // Build context source: prefer reference words, then whisper, then apple.
        let contextWords: [EngineWord] = referenceWords ?? whisperWords ?? appleWords ?? []

        var entries: [DisagreementEntry] = []
        for (idx, region) in sorted.enumerated() {
            let seqNum = idx + 1
            let idStr = String(format: "%@-d%04d", meetingID, seqNum)

            let startSec = region.regionTimeStart ?? 0
            let endSec = region.regionTimeEnd ?? startSec

            let m = Int(startSec) / 60
            let s = Int(startSec) % 60
            let timeStr = "\(m):\(String(format: "%02d", s))"

            let ctxBefore = contextString(before: startSec, from: contextWords, count: 15)
            let ctxAfter = contextString(after: endSec, from: contextWords, count: 15)

            entries.append(DisagreementEntry(
                id: idStr,
                startSeconds: (startSec * 100).rounded() / 100,
                endSeconds: (endSec * 100).rounded() / 100,
                time: timeStr,
                apple: region.appleText,
                whisper: region.whisperText,
                reference: hasReference ? region.refText : nil,
                contextBefore: ctxBefore,
                contextAfter: ctxAfter
            ))
        }

        return entries
    }

    /// Get ~count words of context before a time point.
    static func contextString(before time: Double, from words: [EngineWord],
                              count: Int) -> String {
        // Find words ending before the region start.
        let before = words.filter { w in
            guard let end = w.end else { return false }
            return end <= time + 0.05
        }
        let last = before.suffix(count)
        return last.map(\.text).joined(separator: " ")
    }

    /// Get ~count words of context after a time point.
    static func contextString(after time: Double, from words: [EngineWord],
                              count: Int) -> String {
        let after = words.filter { w in
            guard let start = w.start else { return false }
            return start >= time - 0.05
        }
        let first = after.prefix(count)
        return first.map(\.text).joined(separator: " ")
    }
}

// MARK: - LLM judgement aggregation for the report

/// Overall LLM judgement summary for the report.
public struct LLMJudgement: Codable, Sendable {
    public var meetingsJudged: Int
    public var meetingsNotJudged: Int
    public var appleWins: SeverityCounts
    public var whisperWins: SeverityCounts
    public var bothAcceptable: Int
    public var unknown: Int
    public var undecided: Int
    public var invalid: Int
    public var mistakesThatMatter: [MistakeEntry]
    public var caveats: [String]

    public init(meetingsJudged: Int = 0, meetingsNotJudged: Int = 0,
                appleWins: SeverityCounts = SeverityCounts(),
                whisperWins: SeverityCounts = SeverityCounts(),
                bothAcceptable: Int = 0, unknown: Int = 0,
                undecided: Int = 0, invalid: Int = 0,
                mistakesThatMatter: [MistakeEntry] = [],
                caveats: [String] = []) {
        self.meetingsJudged = meetingsJudged
        self.meetingsNotJudged = meetingsNotJudged
        self.appleWins = appleWins
        self.whisperWins = whisperWins
        self.bothAcceptable = bothAcceptable
        self.unknown = unknown
        self.undecided = undecided
        self.invalid = invalid
        self.mistakesThatMatter = mistakesThatMatter
        self.caveats = caveats
    }
}

/// Win counts by severity.
public struct SeverityCounts: Codable, Sendable, Equatable {
    public var low: Int
    public var med: Int
    public var high: Int
    public var total: Int { low + med + high }

    public init(low: Int = 0, med: Int = 0, high: Int = 0) {
        self.low = low
        self.med = med
        self.high = high
    }
}

/// A mistake entry for the "Mistakes that matter" section.
public struct MistakeEntry: Codable, Sendable {
    public var meetingID: String
    public var time: String
    public var decision: String
    public var severity: String
    public var appleText: String
    public var whisperText: String
    public var referenceText: String?
    public var startSeconds: Double

    public init(meetingID: String, time: String, decision: String, severity: String,
                appleText: String, whisperText: String, referenceText: String? = nil,
                startSeconds: Double = 0) {
        self.meetingID = meetingID
        self.time = time
        self.startSeconds = startSeconds
        self.decision = decision
        self.severity = severity
        self.appleText = appleText
        self.whisperText = whisperText
        self.referenceText = referenceText
    }
}

/// Per-meeting LLM counts for the per-meeting table.
public struct MeetingLLMCounts: Codable, Sendable {
    public var judged: Bool
    public var appleWins: Int
    public var whisperWins: Int
    public var bothAcceptable: Int
    public var unknown: Int
    public var undecided: Int
    public var invalid: Int
    public var appleHighLosses: Int
    public var whisperHighLosses: Int

    public init(judged: Bool = false, appleWins: Int = 0, whisperWins: Int = 0,
                bothAcceptable: Int = 0, unknown: Int = 0,
                undecided: Int = 0, invalid: Int = 0,
                appleHighLosses: Int = 0, whisperHighLosses: Int = 0) {
        self.judged = judged
        self.appleWins = appleWins
        self.whisperWins = whisperWins
        self.bothAcceptable = bothAcceptable
        self.unknown = unknown
        self.undecided = undecided
        self.invalid = invalid
        self.appleHighLosses = appleHighLosses
        self.whisperHighLosses = whisperHighLosses
    }
}

/// Aggregate all meeting decisions into the overall LLM judgement and per-meeting counts.
public enum LLMJudgementAggregator {

    public static func aggregate(
        meetingResults: [MeetingDecisionResult]
    ) -> (overall: LLMJudgement, perMeeting: [String: MeetingLLMCounts]) {
        var overall = LLMJudgement()
        var perMeeting: [String: MeetingLLMCounts] = [:]
        var allMistakes: [MistakeEntry] = []
        var allCaveats: [String] = []
        var unknownSeverityWins = 0

        for result in meetingResults {
            var counts = MeetingLLMCounts(judged: result.judged)

            if result.judged {
                overall.meetingsJudged += 1
            } else {
                overall.meetingsNotJudged += 1
            }

            // Parser warnings already include the fingerprint-mismatch caveat.
            allCaveats.append(contentsOf: result.warnings)

            for d in result.decisions {
                switch d.decision {
                case .appleWins:
                    counts.appleWins += 1
                    switch d.severity {
                    case .low: overall.appleWins.low += 1
                    case .med: overall.appleWins.med += 1
                    case .high:
                        overall.appleWins.high += 1
                        counts.whisperHighLosses += 1
                    case .unknown:
                        overall.appleWins.low += 1
                        unknownSeverityWins += 1
                    }
                    if d.severity == .high || d.severity == .med {
                        allMistakes.append(MistakeEntry(
                            meetingID: d.meetingID, time: d.time,
                            decision: d.decision.rawValue, severity: d.severity.rawValue,
                            appleText: d.appleText, whisperText: d.whisperText,
                            referenceText: d.referenceText, startSeconds: d.startSeconds
                        ))
                    }
                case .whisperWins:
                    counts.whisperWins += 1
                    switch d.severity {
                    case .low: overall.whisperWins.low += 1
                    case .med: overall.whisperWins.med += 1
                    case .high:
                        overall.whisperWins.high += 1
                        counts.appleHighLosses += 1
                    case .unknown:
                        overall.whisperWins.low += 1
                        unknownSeverityWins += 1
                    }
                    if d.severity == .high || d.severity == .med {
                        allMistakes.append(MistakeEntry(
                            meetingID: d.meetingID, time: d.time,
                            decision: d.decision.rawValue, severity: d.severity.rawValue,
                            appleText: d.appleText, whisperText: d.whisperText,
                            referenceText: d.referenceText, startSeconds: d.startSeconds
                        ))
                    }
                case .bothAcceptable:
                    overall.bothAcceptable += 1
                    counts.bothAcceptable += 1
                case .unknown:
                    overall.unknown += 1
                    counts.unknown += 1
                case .undecided:
                    overall.undecided += 1
                    counts.undecided += 1
                case .invalid:
                    overall.invalid += 1
                    counts.invalid += 1
                }
            }

            perMeeting[result.meetingID] = counts
        }

        // Sort mistakes: high first, then med, by meeting then time.
        let highMistakes = allMistakes
            .filter { $0.severity == "high" }
            .sorted { ($0.meetingID, $0.startSeconds) < ($1.meetingID, $1.startSeconds) }
        let medMistakes = allMistakes
            .filter { $0.severity == "med" }
            .sorted { ($0.meetingID, $0.startSeconds) < ($1.meetingID, $1.startSeconds) }
            .prefix(40)

        overall.mistakesThatMatter = highMistakes + medMistakes
        if unknownSeverityWins > 0 {
            allCaveats.append("\(unknownSeverityWins) win(s) had no valid severity and are counted as low")
        }
        overall.caveats = allCaveats

        return (overall, perMeeting)
    }
}
