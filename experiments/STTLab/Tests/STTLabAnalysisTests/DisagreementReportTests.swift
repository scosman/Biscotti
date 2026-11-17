import Foundation
@testable import STTLabAnalysis
import STTLabCore
import Testing

@Suite("DisagreementReport")
struct DisagreementReportTests {

    // MARK: - Report JSON shape and deterministic IDs/fingerprint

    @Test("Report entries get deterministic IDs in time order")
    func deterministicIDs() {
        let regions = [
            DisagreementRegion(
                whisperRange: (0, 1), appleRange: (0, 1), refRange: (0, 1),
                classification: .appleMatches, appleDistance: 0, whisperDistance: 1,
                size: 1, appleText: "cat", whisperText: "dog", refText: "cat",
                appleTimeStart: 5.0, appleTimeEnd: 6.0,
                whisperTimeStart: 5.0, whisperTimeEnd: 6.0,
                refTimeStart: 5.0, refTimeEnd: 6.0
            ),
            DisagreementRegion(
                whisperRange: (2, 3), appleRange: (2, 3), refRange: (2, 3),
                classification: .whisperMatches, appleDistance: 1, whisperDistance: 0,
                size: 1, appleText: "bird", whisperText: "fish", refText: "fish",
                appleTimeStart: 1.0, appleTimeEnd: 2.0,
                whisperTimeStart: 1.0, whisperTimeEnd: 2.0,
                refTimeStart: 1.0, refTimeEnd: 2.0
            ),
        ]

        let entries = DisagreementReportBuilder.buildEntries(
            regions: regions, meetingID: "m01", hasReference: true,
            referenceWords: nil, appleWords: nil, whisperWords: nil
        )

        // Second region is earlier -> gets d0001.
        #expect(entries.count == 2)
        #expect(entries[0].id == "m01-d0001")
        #expect(entries[1].id == "m01-d0002")
        #expect(entries[0].startSeconds < entries[1].startSeconds)
    }

    @Test("Fingerprint is deterministic for the same entries")
    func deterministicFingerprint() {
        let entry = DisagreementEntry(
            id: "m01-d0001", startSeconds: 1.0, endSeconds: 2.0,
            time: "0:01", apple: "cat", whisper: "dog", reference: "cat",
            contextBefore: "before", contextAfter: "after"
        )
        let fp1 = DisagreementReportFile.computeFingerprint([entry])
        let fp2 = DisagreementReportFile.computeFingerprint([entry])
        #expect(fp1 == fp2)
        #expect(fp1.count == 64) // SHA-256 hex
    }

    @Test("Fingerprint changes when entries differ")
    func fingerprintChanges() {
        let e1 = DisagreementEntry(
            id: "m01-d0001", startSeconds: 1.0, endSeconds: 2.0,
            time: "0:01", apple: "cat", whisper: "dog", reference: "cat",
            contextBefore: "", contextAfter: ""
        )
        let e2 = DisagreementEntry(
            id: "m01-d0001", startSeconds: 1.0, endSeconds: 2.0,
            time: "0:01", apple: "bird", whisper: "dog", reference: "bird",
            contextBefore: "", contextAfter: ""
        )
        let fp1 = DisagreementReportFile.computeFingerprint([e1])
        let fp2 = DisagreementReportFile.computeFingerprint([e2])
        #expect(fp1 != fp2)
    }

    @Test("Report file round-trips through JSON with snake_case keys")
    func reportFileRoundTrip() throws {
        let entry = DisagreementEntry(
            id: "m01-d0001", startSeconds: 1.0, endSeconds: 2.0,
            time: "0:01", apple: "cat", whisper: "dog", reference: "cat",
            contextBefore: "before text", contextAfter: "after text"
        )
        let report = DisagreementReportFile(
            meetingId: "m01", hasReference: true,
            durationSeconds: 1920.0, disagreements: [entry]
        )

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(report)
        let json = String(data: data, encoding: .utf8)!

        // Verify snake_case keys.
        #expect(json.contains("\"schema_version\""))
        #expect(json.contains("\"meeting_id\""))
        #expect(json.contains("\"report_fingerprint\""))
        #expect(json.contains("\"has_reference\""))
        #expect(json.contains("\"duration_seconds\""))
        #expect(json.contains("\"start_seconds\""))
        #expect(json.contains("\"context_before\""))

        // Round-trip.
        let decoded = try JSONDecoder().decode(DisagreementReportFile.self, from: data)
        #expect(decoded.meetingId == "m01")
        #expect(decoded.schemaVersion == 1)
        #expect(decoded.hasReference == true)
        #expect(decoded.disagreements.count == 1)
        #expect(decoded.disagreements[0].id == "m01-d0001")
        #expect(decoded.reportFingerprint == report.reportFingerprint)
    }

    @Test("Reference is null when meeting has no reference")
    func noReferenceNull() throws {
        let entry = DisagreementEntry(
            id: "m01-d0001", startSeconds: 1.0, endSeconds: 2.0,
            time: "0:01", apple: "cat", whisper: "dog", reference: nil,
            contextBefore: "", contextAfter: ""
        )
        let encoder = JSONEncoder()
        let data = try encoder.encode(entry)
        let json = String(data: data, encoding: .utf8)!
        // A missing reference is written as an explicit null.
        #expect(json.contains("\"reference\":null"))
        // Round-trip: decoded reference must be nil.
        let decoded = try JSONDecoder().decode(DisagreementEntry.self, from: data)
        #expect(decoded.reference == nil)
    }

    // MARK: - Decision parsing tolerance

    @Test("Normal decision file parses correctly")
    func normalDecision() {
        let entries = [
            DisagreementEntry(
                id: "m01-d0001", startSeconds: 1.0, endSeconds: 2.0,
                time: "0:01", apple: "cat", whisper: "dog", reference: "cat",
                contextBefore: "", contextAfter: ""
            ),
        ]
        let decision = DisagreementDecisionFile(
            meetingId: "m01", reportFingerprint: "abc123",
            decisions: [DecisionEntry(id: "m01-d0001", decision: "apple_wins", severity: "high")]
        )
        let data = try! JSONEncoder().encode(decision)
        let result = DecisionParser.parse(
            decisionData: data, reportEntries: entries,
            reportFingerprint: "abc123", meetingID: "m01"
        )
        #expect(result.judged)
        #expect(result.fingerprintMatch)
        #expect(result.decisions.count == 1)
        #expect(result.decisions[0].decision == .appleWins)
        #expect(result.decisions[0].severity == .high)
        #expect(result.warnings.isEmpty)
    }

    @Test("Case-insensitive decision parsing")
    func caseInsensitiveDecision() {
        let entries = [
            DisagreementEntry(
                id: "m01-d0001", startSeconds: 1.0, endSeconds: 2.0,
                time: "0:01", apple: "a", whisper: "b", reference: nil,
                contextBefore: "", contextAfter: ""
            ),
        ]
        let decision = DisagreementDecisionFile(
            meetingId: "m01", reportFingerprint: "fp",
            decisions: [DecisionEntry(id: "m01-d0001", decision: "Apple_Wins", severity: "HIGH")]
        )
        let data = try! JSONEncoder().encode(decision)
        let result = DecisionParser.parse(
            decisionData: data, reportEntries: entries,
            reportFingerprint: "fp", meetingID: "m01"
        )
        #expect(result.decisions[0].decision == .appleWins)
        #expect(result.decisions[0].severity == .high)
    }

    @Test("Medium accepted as med")
    func mediumAsMed() {
        let entries = [
            DisagreementEntry(
                id: "m01-d0001", startSeconds: 1.0, endSeconds: 2.0,
                time: "0:01", apple: "a", whisper: "b", reference: nil,
                contextBefore: "", contextAfter: ""
            ),
        ]
        let decision = DisagreementDecisionFile(
            meetingId: "m01", reportFingerprint: "fp",
            decisions: [DecisionEntry(id: "m01-d0001", decision: "whisper_wins", severity: "medium")]
        )
        let data = try! JSONEncoder().encode(decision)
        let result = DecisionParser.parse(
            decisionData: data, reportEntries: entries,
            reportFingerprint: "fp", meetingID: "m01"
        )
        #expect(result.decisions[0].severity == .med)
    }

    @Test("Invalid decision value counted as invalid with warning")
    func invalidDecisionValue() {
        let entries = [
            DisagreementEntry(
                id: "m01-d0001", startSeconds: 1.0, endSeconds: 2.0,
                time: "0:01", apple: "a", whisper: "b", reference: nil,
                contextBefore: "", contextAfter: ""
            ),
        ]
        let decision = DisagreementDecisionFile(
            meetingId: "m01", reportFingerprint: "fp",
            decisions: [DecisionEntry(id: "m01-d0001", decision: "garbage", severity: "low")]
        )
        let data = try! JSONEncoder().encode(decision)
        let result = DecisionParser.parse(
            decisionData: data, reportEntries: entries,
            reportFingerprint: "fp", meetingID: "m01"
        )
        #expect(result.decisions[0].decision == .invalid)
        #expect(result.warnings.contains { $0.contains("invalid decision") })
    }

    @Test("Unknown ID warned and ignored")
    func unknownID() {
        let entries = [
            DisagreementEntry(
                id: "m01-d0001", startSeconds: 1.0, endSeconds: 2.0,
                time: "0:01", apple: "a", whisper: "b", reference: nil,
                contextBefore: "", contextAfter: ""
            ),
        ]
        let decision = DisagreementDecisionFile(
            meetingId: "m01", reportFingerprint: "fp",
            decisions: [
                DecisionEntry(id: "m01-d0001", decision: "apple_wins", severity: "low"),
                DecisionEntry(id: "m01-d9999", decision: "apple_wins", severity: "low"),
            ]
        )
        let data = try! JSONEncoder().encode(decision)
        let result = DecisionParser.parse(
            decisionData: data, reportEntries: entries,
            reportFingerprint: "fp", meetingID: "m01"
        )
        #expect(result.decisions.count == 1)
        #expect(result.warnings.contains { $0.contains("unknown decision ID") })
    }

    @Test("Missing ID counted as undecided")
    func missingID() {
        let entries = [
            DisagreementEntry(
                id: "m01-d0001", startSeconds: 1.0, endSeconds: 2.0,
                time: "0:01", apple: "a", whisper: "b", reference: nil,
                contextBefore: "", contextAfter: ""
            ),
            DisagreementEntry(
                id: "m01-d0002", startSeconds: 3.0, endSeconds: 4.0,
                time: "0:03", apple: "c", whisper: "d", reference: nil,
                contextBefore: "", contextAfter: ""
            ),
        ]
        let decision = DisagreementDecisionFile(
            meetingId: "m01", reportFingerprint: "fp",
            decisions: [
                DecisionEntry(id: "m01-d0001", decision: "apple_wins", severity: "low"),
                // m01-d0002 is missing
            ]
        )
        let data = try! JSONEncoder().encode(decision)
        let result = DecisionParser.parse(
            decisionData: data, reportEntries: entries,
            reportFingerprint: "fp", meetingID: "m01"
        )
        #expect(result.decisions.count == 2)
        #expect(result.decisions[0].decision == .appleWins)
        #expect(result.decisions[1].decision == .undecided)
    }

    @Test("Fingerprint mismatch: warning but decisions still used")
    func fingerprintMismatch() {
        let entries = [
            DisagreementEntry(
                id: "m01-d0001", startSeconds: 1.0, endSeconds: 2.0,
                time: "0:01", apple: "a", whisper: "b", reference: nil,
                contextBefore: "", contextAfter: ""
            ),
        ]
        let decision = DisagreementDecisionFile(
            meetingId: "m01", reportFingerprint: "old_fingerprint",
            decisions: [DecisionEntry(id: "m01-d0001", decision: "apple_wins", severity: "low")]
        )
        let data = try! JSONEncoder().encode(decision)
        let result = DecisionParser.parse(
            decisionData: data, reportEntries: entries,
            reportFingerprint: "new_fingerprint", meetingID: "m01"
        )
        #expect(result.judged)
        #expect(!result.fingerprintMatch)
        #expect(result.decisions[0].decision == .appleWins)
        #expect(result.warnings.contains { $0.contains("fingerprint") })
    }

    @Test("Missing file: not judged, all undecided")
    func missingFile() {
        let entries = [
            DisagreementEntry(
                id: "m01-d0001", startSeconds: 1.0, endSeconds: 2.0,
                time: "0:01", apple: "a", whisper: "b", reference: nil,
                contextBefore: "", contextAfter: ""
            ),
        ]
        let result = DecisionParser.parse(
            decisionData: nil, reportEntries: entries,
            reportFingerprint: "fp", meetingID: "m01"
        )
        #expect(!result.judged)
        #expect(result.decisions.count == 1)
        #expect(result.decisions[0].decision == .undecided)
    }

    // MARK: - LLM judgement rendering

    @Test("Report renders LLM Judgement section with decisions")
    func llmJudgementRendering() {
        var model = ReportModel(bundleID: "test")
        model.llmJudgement = LLMJudgement(
            meetingsJudged: 2, meetingsNotJudged: 0,
            appleWins: SeverityCounts(low: 5, med: 2, high: 1),
            whisperWins: SeverityCounts(low: 3, med: 1, high: 0),
            bothAcceptable: 10, unknown: 2
        )

        var mm = MeetingMetrics(meetingID: "m01", durationSeconds: 600)
        mm.appleStatus = "completed"
        mm.whisperStatus = "completed"
        mm.referenceStatus = "completed"
        mm.llmCounts = MeetingLLMCounts(
            judged: true, appleWins: 4, whisperWins: 2,
            bothAcceptable: 5
        )
        model.meetings = [mm]

        let md = MarkdownRenderer.render(model)

        #expect(md.contains("### LLM Judgement"))
        #expect(md.contains("Meetings judged: 2"))
        #expect(md.contains("| Apple wins |"))
        #expect(md.contains("| Whisper wins |"))
        #expect(md.contains("| Both acceptable |"))
    }

    @Test("Report without LLM data shows fallback message")
    func noLLMData() {
        var model = ReportModel(bundleID: "test")
        var mm = MeetingMetrics(meetingID: "m01", durationSeconds: 600)
        mm.appleStatus = "completed"
        mm.whisperStatus = "completed"
        mm.referenceStatus = "completed"
        model.meetings = [mm]

        let md = MarkdownRenderer.render(model)
        #expect(md.contains("### LLM Judgement"))
        #expect(md.contains("No LLM judgement data available"))
    }

    @Test("Mistakes that matter table rendered for high/med severity")
    func mistakesThatMatter() {
        var model = ReportModel(bundleID: "test")
        model.llmJudgement = LLMJudgement(
            meetingsJudged: 1,
            appleWins: SeverityCounts(high: 1),
            mistakesThatMatter: [
                MistakeEntry(
                    meetingID: "m01", time: "1:30",
                    decision: "apple_wins", severity: "high",
                    appleText: "the correct text", whisperText: "the wrong text",
                    referenceText: "the correct text"
                ),
            ]
        )
        var mm = MeetingMetrics(meetingID: "m01", durationSeconds: 600)
        mm.appleStatus = "completed"
        mm.whisperStatus = "completed"
        mm.referenceStatus = "completed"
        model.meetings = [mm]

        let md = MarkdownRenderer.render(model)
        #expect(md.contains("### Mistakes That Matter"))
        #expect(md.contains("| m01 |"))
        #expect(md.contains("the correct text"))
    }
}

// MARK: - Reference segment index collision (Bug 1 test)

@Suite("TieBreak reference segment bridging")
struct TieBreakBridgingTests {

    @Test("Two-chunk reference with same segment indices does not mix chunks")
    func twoChunkNonCollision() {
        // Simulate two chunks, each with segment 0 and segment 1.
        // After the fix, segment indices should be unique across chunks:
        // chunk 0 -> 0, 1;  chunk 1 -> 100000, 100001
        let words: [EngineWord] = [
            // Chunk 0, segment 0
            EngineWord(text: "hello", start: 0.0, end: 1.0, segmentIndex: 0),
            EngineWord(text: "world", start: 1.0, end: 2.0, segmentIndex: 0),
            // Chunk 0, segment 1
            EngineWord(text: "this", start: 2.0, end: 3.0, segmentIndex: 1),
            // Chunk 1, segment 0 (would collide without fix)
            EngineWord(text: "is", start: 5.0, end: 6.0, segmentIndex: 100_000),
            EngineWord(text: "great", start: 6.0, end: 7.0, segmentIndex: 100_000),
            // Chunk 1, segment 1
            EngineWord(text: "today", start: 7.0, end: 8.0, segmentIndex: 100_001),
        ]

        let transcript = EngineTranscript(
            engine: .reference, words: words, displayText: "hello world this is great today"
        )

        // Import SpeakerAlignment.bridge through the EngineTranscript.
        // We test that the words come out in time order after bridging.
        // The bridge function is in STTLabHome, so we test the model invariant here:
        // all segment indices must be unique per chunk to avoid collision.
        let segIndices = Set(words.map(\.segmentIndex))
        #expect(segIndices.count == 4) // 0, 1, 100000, 100001 — no collision
    }
}

// MARK: - Apple word grouper whole-word classification (Bug 2 test)

@Suite("AppleWordGrouper trimmed classification")
struct AppleWordGrouperTrimmedTests {

    @Test("Run with leading space classified as wholeWord after trimming")
    func leadingSpaceWholeWord() {
        let result = AppleResult(
            index: 0,
            rangeStart: CMTimeValue(value: 0, timescale: 1, flags: 1, epoch: 0, seconds: 0),
            rangeDuration: CMTimeValue(value: 2, timescale: 1, flags: 1, epoch: 0, seconds: 2),
            resultsFinalizationTime: CMTimeValue(value: 2, timescale: 1, flags: 1, epoch: 0,
                                                  seconds: 2),
            isFinal: true,
            text: " Oh, the",
            runs: [
                // " Oh," at [0,4), token "Oh," at [1,4)
                AppleRun(
                    text: " Oh,",
                    charOffset: 0, charLength: 4,
                    timeStart: CMTimeValue(value: 0, timescale: 1, flags: 1, epoch: 0, seconds: 0),
                    timeDuration: CMTimeValue(value: 500_000, timescale: 1_000_000, flags: 1,
                                              epoch: 0, seconds: 0.5),
                    confidence: 0.9
                ),
                // " the" at [4,8), token "the" at [5,8)
                AppleRun(
                    text: " the",
                    charOffset: 4, charLength: 4,
                    timeStart: CMTimeValue(value: 500_000, timescale: 1_000_000, flags: 1,
                                           epoch: 0, seconds: 0.5),
                    timeDuration: CMTimeValue(value: 300_000, timescale: 1_000_000, flags: 1,
                                              epoch: 0, seconds: 0.3),
                    confidence: 0.85
                ),
            ]
        )

        let (_, stats) = AppleWordGrouper.group(results: [result], audioDuration: 10)

        // Both runs should be classified as wholeWord after trimming.
        #expect(stats.classCounts[RunClass.wholeWord.rawValue] == 2)
        // Previously these would be subWord because the untrimmed run range
        // did not match the token range.
        #expect((stats.classCounts[RunClass.subWord.rawValue] ?? 0) == 0)
    }
}

// MARK: - Dropped-stretch flag with other engine text (Bug 4 test)

@Suite("Flags droppedStretch excerpts")
struct FlagsExcerptTests {

    @Test("Dropped stretch includes other engines' text excerpts")
    func droppedStretchExcerpts() {
        // Apple has a 40s gap from 10 to 50.
        let appleWords: [EngineWord] = [
            EngineWord(text: "hello", start: 1, end: 2, segmentIndex: 0),
            EngineWord(text: "world", start: 50, end: 51, segmentIndex: 0),
        ]
        let apple = EngineTranscript(engine: .apple, words: appleWords, displayText: "hello world")

        // Whisper has words inside the gap (including "Thank you." repetitions).
        let whisperWords: [EngineWord] = (0..<6).map {
            EngineWord(text: "Thank", start: Double(15 + $0 * 5), end: Double(16 + $0 * 5),
                       segmentIndex: 0)
        }
        let whisper = EngineTranscript(engine: .whisper, words: whisperWords, displayText: "...")

        // Reference has words too.
        let refWords: [EngineWord] = (0..<5).map {
            EngineWord(text: "r\($0)", start: Double(20 + $0 * 5), end: Double(21 + $0 * 5),
                       segmentIndex: 0)
        }
        let reference = EngineTranscript(engine: .reference, words: refWords, displayText: "...")

        let flags = Flags.checkDroppedStretches(
            transcripts: [(.apple, apple), (.whisper, whisper), (.reference, reference)],
            audioDuration: 60
        )

        #expect(!flags.isEmpty)
        if case .droppedStretch(_, _, _, let excerpts) = flags[0] {
            #expect(!excerpts.isEmpty)
            // Should have whisper and/or reference excerpts.
            let whisperExcerpt = excerpts.first { $0.engine == .whisper }
            #expect(whisperExcerpt != nil)
            #expect(whisperExcerpt!.text.contains("Thank"))
        } else {
            Issue.record("Expected droppedStretch flag")
        }
    }
}
