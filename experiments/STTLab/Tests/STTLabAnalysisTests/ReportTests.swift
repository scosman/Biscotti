import Foundation
@testable import STTLabAnalysis
import STTLabCore
import Testing

@Suite("ReportModel and MarkdownRenderer")
struct ReportTests {

    @Test("ReportModel round-trips through JSON")
    func reportModelCodable() throws {
        var model = ReportModel(bundleID: "test-bundle-id")
        model.homeMachine = ReportMachine(name: "home", chip: "M4", memoryGB: 16, osVersion: "15.1")
        model.runnerMachine = ReportMachine(name: "runner", chip: "M4 Pro", memoryGB: 24, osVersion: "27.0")
        model.referenceModel = "microsoft/mai-transcribe-2"
        model.referenceZDR = true
        model.referenceTotalCost = 0.42
        model.pooledWerAppleVsRef = WERResult(refWords: 1000, substitutions: 50, deletions: 20, insertions: 10)

        var mm = MeetingMetrics(meetingID: "m01", durationSeconds: 1800, speakerCount: 3, locale: "en_US")
        mm.appleStatus = "completed"
        mm.whisperStatus = "completed"
        mm.referenceStatus = "completed"
        mm.werAppleVsRef = WERResult(refWords: 500, substitutions: 25, deletions: 10, insertions: 5)
        model.meetings = [mm]

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(model)
        let decoded = try JSONDecoder().decode(ReportModel.self, from: data)

        #expect(decoded.bundleID == "test-bundle-id")
        #expect(decoded.meetings.count == 1)
        #expect(decoded.meetings[0].meetingID == "m01")
        #expect(decoded.pooledWerAppleVsRef?.substitutions == 50)
        #expect(decoded.homeMachine?.chip == "M4")
        #expect(decoded.runnerMachine?.chip == "M4 Pro")
    }

    @Test("MarkdownRenderer includes all expected sections")
    func rendererSections() {
        var model = ReportModel(bundleID: "test-id")
        model.homeMachine = ReportMachine(name: "home", chip: "M4", memoryGB: 16, osVersion: "15.1")
        model.runnerMachine = ReportMachine(name: "runner", chip: "M4 Pro", memoryGB: 24, osVersion: "27.0")
        model.referenceModel = "test-model"
        model.pooledWerAppleVsRef = WERResult(refWords: 100, substitutions: 5, deletions: 2, insertions: 1)
        model.pooledWerWhisperVsRef = WERResult(refWords: 100, substitutions: 3, deletions: 1, insertions: 0)
        model.overallTieBreakCounts = TieBreakCounts(
            byRegion: ["appleMatches": 5, "whisperMatches": 3],
            byTokens: ["appleMatches": 10, "whisperMatches": 6]
        )

        var mm = MeetingMetrics(meetingID: "m01", durationSeconds: 1800, speakerCount: 2)
        mm.appleStatus = "completed"
        mm.whisperStatus = "completed"
        mm.referenceStatus = "completed"
        model.meetings = [mm]

        let markdown = MarkdownRenderer.render(model)

        // Check for expected section headings.
        #expect(markdown.contains("# STTLab Report"))
        #expect(markdown.contains("## Run Summary"))
        #expect(markdown.contains("## Summary"))
        #expect(markdown.contains("## Per-Meeting Results"))
        #expect(markdown.contains("## Speed"))
        #expect(markdown.contains("## Accuracy"))
        #expect(markdown.contains("## Text Quality"))
        #expect(markdown.contains("## Word Timing"))
        #expect(markdown.contains("## Speaker Alignment"))
        #expect(markdown.contains("## Other"))
        #expect(markdown.contains("## Caveats"))
        #expect(markdown.contains("### Stability"))
    }

    @Test("MarkdownRenderer handles missing engines as n/a")
    func rendererMissingEngines() {
        var model = ReportModel(bundleID: "test-id")
        var mm = MeetingMetrics(meetingID: "m01", durationSeconds: 600)
        mm.appleStatus = "not run"
        mm.whisperStatus = "completed"
        mm.referenceStatus = "failed"
        model.meetings = [mm]

        let markdown = MarkdownRenderer.render(model)

        // WER should show n/a.
        #expect(markdown.contains("n/a"))
        // Should not crash on missing data.
        #expect(markdown.contains("## Run Summary"))
    }

    @Test("MeetingMetrics round-trips")
    func meetingMetricsCodable() throws {
        var mm = MeetingMetrics(meetingID: "m02", durationSeconds: 3600,
                                speakerCount: 4, locale: "en_US")
        mm.appleStatus = "completed"
        mm.whisperStatus = "failed"
        mm.referenceStatus = "not run"
        mm.flags = ["werRatio: big difference"]
        mm.textQualityApple = TextQualityResult(
            wordCount: 500, punctuationPer100Words: 12.5,
            sentenceCount: 30, sentenceStartCapitalizedShare: 0.95,
            midSentenceCapitalizedShare: 0.02,
            fillerCounts: ["um": 5], fillerTotal: 5,
            fillerPer1000Words: 10.0
        )

        let data = try JSONEncoder().encode(mm)
        let decoded = try JSONDecoder().decode(MeetingMetrics.self, from: data)

        #expect(decoded.meetingID == "m02")
        #expect(decoded.flags.count == 1)
        #expect(decoded.textQualityApple?.wordCount == 500)
    }
}
