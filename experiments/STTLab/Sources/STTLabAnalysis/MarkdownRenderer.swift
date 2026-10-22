import Foundation
import STTLabCore

/// Renders a `ReportModel` to a Markdown report string.
public enum MarkdownRenderer {

    public static func render(_ model: ReportModel) -> String {
        var lines: [String] = []

        lines.append("# STTLab Report")
        lines.append("")

        // Section 1: Run summary.
        renderRunSummary(model, into: &lines)

        // Section 2: Summary table.
        renderSummaryTable(model, into: &lines)

        // Section 3: Per-meeting table.
        renderPerMeetingTable(model, into: &lines)

        // Section 4: Speed.
        renderSpeed(model, into: &lines)

        // Section 5: Accuracy.
        renderAccuracy(model, into: &lines)

        // Section 6: Text quality.
        renderTextQuality(model, into: &lines)

        // Section 7: Timing.
        renderTiming(model, into: &lines)

        // Section 8: Speakers.
        renderSpeakers(model, into: &lines)

        // Section 9: Other (stability, memory, locale).
        renderOther(model, into: &lines)

        // Section 10: Caveats.
        renderCaveats(model, into: &lines)

        return lines.joined(separator: "\n")
    }

    // MARK: - Run summary

    static func renderRunSummary(_ m: ReportModel, into lines: inout [String]) {
        lines.append("## Run Summary")
        lines.append("")
        lines.append("- **Bundle ID:** \(m.bundleID)")
        if let home = m.homeMachine {
            lines.append("- **Home Mac:** \(home.chip), \(home.memoryGB) GB RAM, \(home.osVersion)")
        }
        if let runner = m.runnerMachine {
            lines.append("- **Runner Mac:** \(runner.chip), \(runner.memoryGB) GB RAM, \(runner.osVersion)")
        }
        if let ref = m.referenceModel {
            lines.append("- **Reference model:** \(ref)")
        }
        if let zdr = m.referenceZDR {
            lines.append("- **ZDR:** \(zdr ? "yes" : "no")")
        }
        if let cost = m.referenceTotalCost {
            lines.append("- **Reference total cost:** $\(fmt2(cost))")
        }
        lines.append("- **Meetings:** \(m.meetings.count)")

        // Status table.
        lines.append("")
        lines.append("| Meeting | Duration | Speakers | Apple | Whisper | Reference |")
        lines.append("|---|---|---|---|---|---|")
        for mtg in m.meetings {
            let dur = formatDuration(mtg.durationSeconds)
            lines.append("| \(mtg.meetingID) | \(dur) | \(mtg.speakerCount) | \(mtg.appleStatus) | \(mtg.whisperStatus) | \(mtg.referenceStatus) |")
        }
        lines.append("")
    }

    // MARK: - Summary table

    static func renderSummaryTable(_ m: ReportModel, into lines: inout [String]) {
        lines.append("## Summary")
        lines.append("")
        lines.append("| Metric | Apple | Whisper |")
        lines.append("|---|---|---|")

        let aWER = m.pooledWerAppleVsRef?.wer.map { fmtPct($0) } ?? "n/a"
        let wWER = m.pooledWerWhisperVsRef?.wer.map { fmtPct($0) } ?? "n/a"
        lines.append("| WER vs reference | \(aWER) | \(wWER) |")

        let tbA = tieBreakWins(m.overallTieBreakCounts, engine: "apple")
        let tbW = tieBreakWins(m.overallTieBreakCounts, engine: "whisper")
        lines.append("| Tie-break wins (region) | \(tbA) | \(tbW) |")

        let tbTokA = tieBreakWinsByTokens(m.overallTieBreakCounts, engine: "apple")
        let tbTokW = tieBreakWinsByTokens(m.overallTieBreakCounts, engine: "whisper")
        lines.append("| Tie-break wins (tokens) | \(tbTokA) | \(tbTokW) |")

        let aRTF = m.medianAppleRTF.map { fmt2($0) + "x" } ?? "n/a"
        let wRTF = m.medianWhisperRTF.map { fmt2($0) + "x" } ?? "n/a"
        let aLabel = m.runnerMachine.map { " (\($0.name))" } ?? ""
        let wLabel = m.homeMachine.map { " (\($0.name))" } ?? ""
        lines.append("| Median RTF | \(aRTF)\(aLabel) | \(wRTF)\(wLabel) |")

        let aTiming = m.overallTimingAW?.startStats.medianAbs.map { fmt3($0) + "s" } ?? "n/a"
        lines.append("| Median |ΔStart| A-W | \(aTiming) | — |")

        let aTimingRef = m.overallTimingAR?.startStats.medianAbs.map { fmt3($0) + "s" } ?? "n/a"
        let wTimingRef = m.overallTimingWR?.startStats.medianAbs.map { fmt3($0) + "s" } ?? "n/a"
        lines.append("| Median |ΔStart| vs ref | \(aTimingRef) | \(wTimingRef) |")

        let spkAgree = m.overallSpeakerAgreementAW?.timeAgreement.map { fmtPct($0) } ?? "n/a"
        lines.append("| Speaker agreement (time) | \(spkAgree) | — |")

        lines.append("")
    }

    // MARK: - Per-meeting table

    static func renderPerMeetingTable(_ m: ReportModel, into lines: inout [String]) {
        lines.append("## Per-Meeting Results")
        lines.append("")
        lines.append("| Meeting | Duration | Speakers | WER A | WER W | A-W disagree | TB A wins | TB W wins | Median |ΔStart| A-W | Speaker agree | Flags |")
        lines.append("|---|---|---|---|---|---|---|---|---|---|---|")

        for mtg in m.meetings {
            let dur = formatDuration(mtg.durationSeconds)
            let spkrs = "\(mtg.speakerCount)"
            let aWER = mtg.werAppleVsRef?.wer.map { fmtPct($0) } ?? "n/a"
            let wWER = mtg.werWhisperVsRef?.wer.map { fmtPct($0) } ?? "n/a"
            let awWER = mtg.werAppleVsWhisper?.wer.map { fmtPct($0) } ?? "n/a"

            let tbA = tieBreakWins(mtg.tieBreakCounts, engine: "apple")
            let tbW = tieBreakWins(mtg.tieBreakCounts, engine: "whisper")

            let medStart = mtg.timingAppleVsWhisper?.startStats.medianAbs.map { fmt3($0) + "s" } ?? "n/a"
            let spkAgree = mtg.speakerAgreementAW?.timeAgreement.map { fmtPct($0) } ?? "n/a"
            let flagStr = mtg.flags.isEmpty ? "—" : mtg.flags.joined(separator: ", ")

            lines.append("| \(mtg.meetingID) | \(dur) | \(spkrs) | \(aWER) | \(wWER) | \(awWER) | \(tbA) | \(tbW) | \(medStart) | \(spkAgree) | \(flagStr) |")
        }
        lines.append("")
    }

    // MARK: - Speed

    static func renderSpeed(_ m: ReportModel, into lines: inout [String]) {
        lines.append("## Speed")
        lines.append("")
        lines.append("> Apple and Whisper run on different Macs. Speed comparisons are cross-machine.")
        lines.append("")

        lines.append("| Meeting | Apple RTF | Apple machine | Whisper RTF | Whisper machine |")
        lines.append("|---|---|---|---|---|")
        for mtg in m.meetings {
            let aRTF = mtg.appleRTF.map { fmt2($0) + "x" } ?? "n/a"
            let wRTF = mtg.whisperRTF.map { fmt2($0) + "x" } ?? "n/a"
            let aMach = m.runnerMachine?.chip ?? "n/a"
            let wMach = m.homeMachine?.chip ?? "n/a"
            lines.append("| \(mtg.meetingID) | \(aRTF) | \(aMach) | \(wRTF) | \(wMach) |")
        }
        lines.append("")
    }

    // MARK: - Accuracy

    static func renderAccuracy(_ m: ReportModel, into lines: inout [String]) {
        lines.append("## Accuracy")
        lines.append("")

        // S/D/I table.
        lines.append("### WER Breakdown (pooled)")
        lines.append("")
        lines.append("| Pair | Ref words | S | D | I | WER |")
        lines.append("|---|---|---|---|---|---|")
        if let w = m.pooledWerAppleVsRef {
            lines.append("| Apple vs Reference | \(w.refWords) | \(w.substitutions) | \(w.deletions) | \(w.insertions) | \(fmtPctOpt(w.wer)) |")
        }
        if let w = m.pooledWerWhisperVsRef {
            lines.append("| Whisper vs Reference | \(w.refWords) | \(w.substitutions) | \(w.deletions) | \(w.insertions) | \(fmtPctOpt(w.wer)) |")
        }
        if let w = m.pooledWerAppleVsWhisper {
            lines.append("| Apple vs Whisper (disagreement) | \(w.refWords) | \(w.substitutions) | \(w.deletions) | \(w.insertions) | \(fmtPctOpt(w.wer)) |")
        }
        lines.append("")

        // Tie-break classes.
        lines.append("### Tie-Break Classification")
        lines.append("")
        if let tb = m.overallTieBreakCounts {
            lines.append("| Class | By region | By tokens |")
            lines.append("|---|---|---|")
            for cls in TieBreakClass.allCases {
                let r = tb.byRegion[cls.rawValue] ?? 0
                let t = tb.byTokens[cls.rawValue] ?? 0
                lines.append("| \(cls.rawValue) | \(r) | \(t) |")
            }
            lines.append("")
        } else {
            lines.append("n/a (reference or one local engine not available)")
            lines.append("")
        }

        // Flags.
        let flaggedMeetings = m.meetings.filter { !$0.flags.isEmpty }
        if !flaggedMeetings.isEmpty {
            lines.append("### Flags")
            lines.append("")
            for mtg in flaggedMeetings {
                for f in mtg.flags {
                    lines.append("- **\(mtg.meetingID):** \(f)")
                }
            }
            lines.append("")
        }

        // Disagreement sample.
        if let sample = m.tieBreakSample, !sample.isEmpty {
            lines.append("### Disagreement Sample")
            lines.append("")
            lines.append("| Meeting | Time | Class | Size | Apple | Whisper | Reference |")
            lines.append("|---|---|---|---|---|---|---|")
            for r in sample {
                let time = r.appleTimeStart.map { formatMmSs($0) } ?? "—"
                let mid = r.meetingID ?? "—"
                lines.append("| \(mid) | \(time) | \(r.classification.rawValue) | \(r.size) | \(truncate(r.appleText, 60)) | \(truncate(r.whisperText, 60)) | \(truncate(r.refText, 60)) |")
            }
            lines.append("")
        }
    }

    // MARK: - Text quality

    static func renderTextQuality(_ m: ReportModel, into lines: inout [String]) {
        lines.append("## Text Quality")
        lines.append("")
        lines.append("| Metric | Apple | Whisper | Reference |")
        lines.append("|---|---|---|---|")

        // Aggregate across meetings.
        let aq = m.meetings.compactMap(\.textQualityApple)
        let wq = m.meetings.compactMap(\.textQualityWhisper)
        let rq = m.meetings.compactMap(\.textQualityReference)

        lines.append("| Punct / 100 words | \(medianField(aq.compactMap(\.punctuationPer100Words))) | \(medianField(wq.compactMap(\.punctuationPer100Words))) | \(medianField(rq.compactMap(\.punctuationPer100Words))) |")
        lines.append("| Sentence start cap % | \(medianField(aq.compactMap(\.sentenceStartCapitalizedShare).map { $0 * 100 })) | \(medianField(wq.compactMap(\.sentenceStartCapitalizedShare).map { $0 * 100 })) | \(medianField(rq.compactMap(\.sentenceStartCapitalizedShare).map { $0 * 100 })) |")
        lines.append("| Mid-sentence cap % | \(medianField(aq.compactMap(\.midSentenceCapitalizedShare).map { $0 * 100 })) | \(medianField(wq.compactMap(\.midSentenceCapitalizedShare).map { $0 * 100 })) | \(medianField(rq.compactMap(\.midSentenceCapitalizedShare).map { $0 * 100 })) |")
        lines.append("| Fillers / 1000 words | \(medianField(aq.compactMap(\.fillerPer1000Words))) | \(medianField(wq.compactMap(\.fillerPer1000Words))) | \(medianField(rq.compactMap(\.fillerPer1000Words))) |")
        lines.append("")
    }

    // MARK: - Timing

    static func renderTiming(_ m: ReportModel, into lines: inout [String]) {
        lines.append("## Word Timing")
        lines.append("")

        if let t = m.overallTimingAW {
            renderTimingPair(t, label: "Apple vs Whisper", into: &lines)
        }
        if let t = m.overallTimingAR {
            renderTimingPair(t, label: "Apple vs Reference", into: &lines)
        } else {
            lines.append("Apple vs Reference timing: n/a (no reference word times)")
            lines.append("")
        }
        if let t = m.overallTimingWR {
            renderTimingPair(t, label: "Whisper vs Reference", into: &lines)
        } else {
            lines.append("Whisper vs Reference timing: n/a (no reference word times)")
            lines.append("")
        }

        // Apple run granularity.
        let allStats = m.meetings.compactMap(\.appleRunStats)
        if !allStats.isEmpty {
            lines.append("### Apple Run Granularity")
            lines.append("")
            var totalRuns = 0
            var aggClass: [String: Int] = [:]
            var aggAnomaly: [String: Int] = [:]
            for s in allStats {
                totalRuns += s.totalRuns
                for (k, v) in s.classCounts { aggClass[k, default: 0] += v }
                for (k, v) in s.anomalyCounts { aggAnomaly[k, default: 0] += v }
            }
            lines.append("Total runs: \(totalRuns)")
            lines.append("")
            lines.append("| Class | Count | Share |")
            lines.append("|---|---|---|")
            for cls in RunClass.allCases {
                let c = aggClass[cls.rawValue] ?? 0
                let share = totalRuns > 0 ? fmtPct(Double(c) / Double(totalRuns)) : "—"
                lines.append("| \(cls.rawValue) | \(c) | \(share) |")
            }
            lines.append("")

            if !aggAnomaly.isEmpty {
                lines.append("| Anomaly | Count |")
                lines.append("|---|---|")
                for a in RunAnomaly.allCases {
                    let c = aggAnomaly[a.rawValue] ?? 0
                    if c > 0 { lines.append("| \(a.rawValue) | \(c) |") }
                }
                lines.append("")
            }
        }
    }

    static func renderTimingPair(_ t: TimingResult, label: String, into lines: inout [String]) {
        lines.append("### \(label)")
        lines.append("")
        lines.append("| Stat | ΔStart | ΔEnd |")
        lines.append("|---|---|---|")
        lines.append("| Pairs | \(t.startStats.pairs) | \(t.endStats.pairs) |")
        lines.append("| Median |Δ| | \(fmtOpt3(t.startStats.medianAbs))s | \(fmtOpt3(t.endStats.medianAbs))s |")
        lines.append("| P90 |Δ| | \(fmtOpt3(t.startStats.p90Abs))s | \(fmtOpt3(t.endStats.p90Abs))s |")
        lines.append("| Max |Δ| | \(fmtOpt3(t.startStats.maxAbs))s | \(fmtOpt3(t.endStats.maxAbs))s |")
        lines.append("| Median signed | \(fmtOpt3(t.startStats.medianSigned))s | \(fmtOpt3(t.endStats.medianSigned))s |")
        lines.append("")
    }

    // MARK: - Speakers

    static func renderSpeakers(_ m: ReportModel, into lines: inout [String]) {
        lines.append("## Speaker Alignment")
        lines.append("")

        if let ag = m.overallSpeakerAgreementAW {
            lines.append("### Apple vs Whisper Agreement")
            lines.append("")
            lines.append("- Time agreement: \(ag.timeAgreement.map { fmtPct($0) } ?? "n/a")")
            lines.append("- Word agreement: \(ag.wordAgreement.map { fmtPct($0) } ?? "n/a")")
            lines.append("")
        }

        if let ag = m.overallSpeakerAgreementAR {
            lines.append("### Apple vs Reference Agreement")
            lines.append("")
            lines.append("> Uses the same diarization as A-W; only the bridged engine differs.")
            lines.append("")
            lines.append("- Time agreement: \(ag.timeAgreement.map { fmtPct($0) } ?? "n/a")")
            lines.append("- Word agreement: \(ag.wordAgreement.map { fmtPct($0) } ?? "n/a")")
            lines.append("")
        }

        if let ag = m.overallSpeakerAgreementWR {
            lines.append("### Whisper vs Reference Agreement")
            lines.append("")
            lines.append("> Uses the same diarization as A-W; only the bridged engine differs.")
            lines.append("")
            lines.append("- Time agreement: \(ag.timeAgreement.map { fmtPct($0) } ?? "n/a")")
            lines.append("- Word agreement: \(ag.wordAgreement.map { fmtPct($0) } ?? "n/a")")
            lines.append("")
        }

        // Segment stats table.
        let aSegs = m.meetings.compactMap(\.segmentStatsApple)
        let wSegs = m.meetings.compactMap(\.segmentStatsWhisper)
        if !aSegs.isEmpty || !wSegs.isEmpty {
            lines.append("### Segment Statistics")
            lines.append("")
            lines.append("| Metric | Apple | Whisper |")
            lines.append("|---|---|---|")
            lines.append("| Total segments | \(aSegs.reduce(0) { $0 + $1.segmentCount }) | \(wSegs.reduce(0) { $0 + $1.segmentCount }) |")
            lines.append("| Total turns | \(aSegs.reduce(0) { $0 + $1.turnCount }) | \(wSegs.reduce(0) { $0 + $1.turnCount }) |")
            lines.append("| Total speaker changes | \(aSegs.reduce(0) { $0 + $1.speakerChanges }) | \(wSegs.reduce(0) { $0 + $1.speakerChanges }) |")
            lines.append("")
        }

        // Disagreement sample.
        let allDisagreements = m.meetings.flatMap { mtg in
            (mtg.speakerDisagreementSample ?? []).map { (mtg.meetingID, $0) }
        }.sorted { $0.1.wordCount > $1.1.wordCount }

        if !allDisagreements.isEmpty {
            lines.append("### Speaker Disagreement Sample (top 20)")
            lines.append("")
            lines.append("| Meeting | Time | Words | Speaker W | Speaker A | Nearest boundary |")
            lines.append("|---|---|---|---|---|---|")
            for (mid, run) in allDisagreements.prefix(20) {
                let time = run.timeStart.map { formatMmSs($0) } ?? "—"
                let boundary = run.nearestDiarizationBoundary.map { formatMmSs($0) } ?? "—"
                lines.append("| \(mid) | \(time) | \(truncate(run.words, 50)) (\(run.wordCount)) | \(run.speakerA.map(String.init) ?? "?") | \(run.speakerB.map(String.init) ?? "?") | \(boundary) |")
            }
            lines.append("")
        }
    }

    // MARK: - Other

    static func renderOther(_ m: ReportModel, into lines: inout [String]) {
        lines.append("## Other")
        lines.append("")

        // Stability.
        lines.append("### Stability")
        lines.append("")
        let appleCompleted = m.meetings.filter { $0.appleStatus == "completed" }.count
        let appleFailed = m.meetings.filter { $0.appleStatus == "failed" }.count
        let whisperCompleted = m.meetings.filter { $0.whisperStatus == "completed" }.count
        let whisperFailed = m.meetings.filter { $0.whisperStatus == "failed" }.count
        let refCompleted = m.meetings.filter { $0.referenceStatus == "completed" }.count
        let refFailed = m.meetings.filter { $0.referenceStatus == "failed" }.count
        lines.append("| Engine | Completed | Failed |")
        lines.append("|---|---|---|")
        lines.append("| Apple | \(appleCompleted) | \(appleFailed) |")
        lines.append("| Whisper | \(whisperCompleted) | \(whisperFailed) |")
        lines.append("| Reference | \(refCompleted) | \(refFailed) |")
        lines.append("")

        if !m.errors.isEmpty {
            lines.append("Errors:")
            for e in m.errors { lines.append("- \(e)") }
            lines.append("")
        }

        // Memory.
        renderMemory(m, into: &lines)

        // Locale coverage.
        let unsupported = m.meetings.filter { $0.appleStatus == "unsupported locale" }
        if !unsupported.isEmpty {
            lines.append("### Locale Coverage")
            lines.append("")
            for mtg in unsupported {
                lines.append("- \(mtg.meetingID): unsupported locale (\(mtg.locale))")
            }
            lines.append("")
        }
    }

    // MARK: - Memory

    static func renderMemory(_ m: ReportModel, into lines: inout [String]) {
        let hasMemory = m.meetings.contains {
            $0.appleMemory != nil || $0.whisperMemory != nil || $0.diarizationMemory != nil
        }
        guard hasMemory else { return }

        lines.append("### Memory")
        lines.append("")
        lines.append("| Meeting | Engine | Process peak | Lifetime peak | System processes |")
        lines.append("|---|---|---|---|---|")

        for mtg in m.meetings {
            if let mem = mtg.appleMemory {
                renderMemoryRow(mtg.meetingID, engine: "Apple", mem: mem, into: &lines)
            }
            if let mem = mtg.whisperMemory {
                renderMemoryRow(mtg.meetingID, engine: "Whisper", mem: mem, into: &lines)
            }
            if let mem = mtg.diarizationMemory {
                renderMemoryRow(mtg.meetingID, engine: "Diarization", mem: mem, into: &lines)
            }
        }
        lines.append("")
    }

    static func renderMemoryRow(_ mid: String, engine: String, mem: MemoryReport,
                                 into lines: inout [String]) {
        let peak = mem.processPeakFootprintBytes.map { formatMB($0) } ?? "n/a"
        let lifetime = mem.processLifetimePeakBytes.map { formatMB($0) } ?? "n/a"
        let sysProcs: String
        if !mem.systemProcesses.isEmpty {
            sysProcs = mem.systemProcesses.map { p in
                "\(p.name) (pid \(p.pid)): \(formatMB(p.peakFootprintBytes))"
            }.joined(separator: "; ")
        } else if let note = mem.systemProcessesNote {
            sysProcs = note
        } else {
            sysProcs = "n/a"
        }
        lines.append("| \(mid) | \(engine) | \(peak) | \(lifetime) | \(sysProcs) |")
    }

    static func formatMB(_ bytes: UInt64) -> String {
        let mb = Double(bytes) / 1_048_576
        return String(format: "%.0f MB", mb)
    }

    // MARK: - Caveats

    static func renderCaveats(_ m: ReportModel, into lines: inout [String]) {
        lines.append("## Caveats")
        lines.append("")

        // Standard caveats.
        var caveats = [
            "Apple and Whisper run on different machines; speed comparisons are cross-machine and not directly comparable.",
            "The reference model is a SOTA approximation, not ground truth. WER measures distance from it, not absolute accuracy.",
            "Text normalization (lowercase, punctuation removed, contractions expanded, numbers spelled out, fillers removed) may hide or introduce small differences.",
            "Apple SpeechTranscriber was run with alternatives enabled; production would not use alternatives.",
            "The Apple speech asset version is unknown (assets update silently).",
        ]

        // Add per-meeting failure caveats.
        for mtg in m.meetings {
            if mtg.appleStatus == "failed" {
                caveats.append("\(mtg.meetingID): Apple failed — excluded from Apple metrics.")
            }
            if mtg.whisperStatus == "failed" {
                caveats.append("\(mtg.meetingID): Whisper failed — excluded from Whisper metrics.")
            }
            if mtg.referenceStatus == "failed" {
                caveats.append("\(mtg.meetingID): Reference failed — excluded from WER and tie-break.")
            }
        }

        caveats.append(contentsOf: m.caveats)
        for c in caveats {
            lines.append("- \(c)")
        }
        lines.append("")
    }

    // MARK: - Formatting helpers

    static func fmt2(_ v: Double) -> String { String(format: "%.2f", v) }
    static func fmt3(_ v: Double) -> String { String(format: "%.3f", v) }
    static func fmtPct(_ v: Double) -> String { String(format: "%.1f%%", v * 100) }
    static func fmtPctOpt(_ v: Double?) -> String { v.map { fmtPct($0) } ?? "n/a" }
    static func fmtOpt3(_ v: Double?) -> String { v.map { fmt3($0) } ?? "n/a" }

    static func formatDuration(_ seconds: Double) -> String {
        let m = Int(seconds) / 60
        let s = Int(seconds) % 60
        return "\(m):\(String(format: "%02d", s))"
    }

    static func formatMmSs(_ seconds: Double) -> String {
        let m = Int(seconds) / 60
        let s = Int(seconds) % 60
        return "\(m):\(String(format: "%02d", s))"
    }

    static func tieBreakWins(_ counts: TieBreakCounts?, engine: String) -> String {
        guard let c = counts else { return "n/a" }
        let matchKey = engine == "apple" ? "appleMatches" : "whisperMatches"
        let closerKey = engine == "apple" ? "appleCloser" : "whisperCloser"
        let matches = c.byRegion[matchKey] ?? 0
        let closer = c.byRegion[closerKey] ?? 0
        return "\(matches + closer)"
    }

    static func tieBreakWinsByTokens(_ counts: TieBreakCounts?, engine: String) -> String {
        guard let c = counts else { return "n/a" }
        let matchKey = engine == "apple" ? "appleMatches" : "whisperMatches"
        let closerKey = engine == "apple" ? "appleCloser" : "whisperCloser"
        let matches = c.byTokens[matchKey] ?? 0
        let closer = c.byTokens[closerKey] ?? 0
        return "\(matches + closer)"
    }

    static func medianField(_ values: [Double]) -> String {
        guard !values.isEmpty else { return "n/a" }
        let sorted = values.sorted()
        let median = sorted[sorted.count / 2]
        return fmt2(median)
    }

    static func truncate(_ s: String, _ maxLen: Int) -> String {
        if s.count <= maxLen { return s }
        return String(s.prefix(maxLen - 3)) + "..."
    }
}
