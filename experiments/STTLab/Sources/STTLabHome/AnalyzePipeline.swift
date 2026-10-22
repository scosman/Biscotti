import Foundation
import SpeakerKit
import STTLabAnalysis
import STTLabCore
import WhisperKit

/// Per-meeting aligned transcripts, stored alongside metrics to avoid recomputation.
public struct MeetingAlignments: Sendable {
    public var appleAligned: AlignedTranscript?
    public var whisperAligned: AlignedTranscript?
    public var referenceAligned: AlignedTranscript?
}

/// Full pipeline result: report model + per-meeting alignments for transcript writing.
public struct PipelineResult: Sendable {
    public var report: ReportModel
    public var alignments: [String: MeetingAlignments]  // keyed by meetingID
}

/// The analyze pipeline: compute all metrics from loaded meeting inputs and produce a ReportModel.
/// Extracted from AnalyzeCommand so it can be tested without the CLI layer.
public enum AnalyzePipeline {

    /// Run the full analyze pipeline.
    ///
    /// - Parameters:
    ///   - meetingInputs: Loaded meeting inputs.
    ///   - manifest: The bundle manifest.
    ///   - runFile: The runner's run.json.
    ///   - log: Logger for status output (pass a no-op log for tests).
    /// - Returns: Pipeline result with report and cached alignments.
    public static func run(
        meetingInputs: [MeetingInputs],
        manifest: BundleManifest,
        runFile: RunFile,
        log: RunLog
    ) -> PipelineResult {
        var allMeetingMetrics: [MeetingMetrics] = []
        var allWerAR: [WERResult] = []
        var allWerWR: [WERResult] = []
        var allWerAW: [WERResult] = []
        var allTieBreakRegions: [DisagreementRegion] = []
        var overallTBByRegion: [String: Int] = [:]
        var overallTBByTokens: [String: Int] = [:]
        var errors: [String] = []
        var allAlignments: [String: MeetingAlignments] = [:]

        // Accumulators for overall timing (raw deltas pooled across meetings).
        var allStartDeltasAW: [Double] = []
        var allEndDeltasAW: [Double] = []
        var allStartDeltasAR: [Double] = []
        var allEndDeltasAR: [Double] = []
        var allStartDeltasWR: [Double] = []
        var allEndDeltasWR: [Double] = []

        for inputs in meetingInputs {
            var mm = MeetingMetrics(
                meetingID: inputs.meetingID,
                durationSeconds: inputs.meta.durationSeconds,
                speakerCount: inputs.meta.speakerCount,
                locale: inputs.meta.appleLocale
            )

            // Engine statuses.
            mm.appleStatus = inputs.appleResult.map {
                $0.status == .completed ? "completed" :
                    ($0.status == .unsupportedLocale ? "unsupported locale" : "failed")
            } ?? "not run"
            mm.whisperStatus = inputs.whisperOutput.map {
                $0.status == .completed ? "completed" : "failed"
            } ?? "not run"
            mm.referenceStatus = inputs.referenceStatus.map {
                $0.status == .completed ? "completed" : "failed"
            } ?? "not run"

            // Collect per-engine errors.
            collectErrors(inputs: inputs, mm: mm, into: &errors)

            // Speed.
            if let timing = inputs.appleResult?.timing {
                mm.appleWallSeconds = timing.wallSeconds
                mm.appleRTF = inputs.meta.durationSeconds / timing.wallSeconds
            }
            if let timing = inputs.whisperOutput?.timing {
                mm.whisperWallSeconds = timing.wallSeconds
                mm.whisperRTF = inputs.meta.durationSeconds / timing.wallSeconds
            }

            // Memory.
            mm.appleMemory = inputs.appleResult?.memory
            mm.whisperMemory = inputs.whisperOutput?.memory
            mm.diarizationMemory = inputs.diarizationOutput?.memory

            // Apple run stats.
            mm.appleRunStats = inputs.appleRunStats

            // Normalize tokens.
            let aToks = inputs.apple.map { Normalizer.tokens(for: $0.words) }
            let wToks = inputs.whisper.map { Normalizer.tokens(for: $0.words) }
            let rToks = inputs.reference.map { Normalizer.tokens(for: $0.words) }

            // WER.
            if let rt = rToks, let at = aToks {
                let wer = WER.compute(ref: rt, hyp: at)
                mm.werAppleVsRef = wer
                allWerAR.append(wer)
            }
            if let rt = rToks, let wt = wToks {
                let wer = WER.compute(ref: rt, hyp: wt)
                mm.werWhisperVsRef = wer
                allWerWR.append(wer)
            }
            if let wt = wToks, let at = aToks {
                let wer = WER.compute(ref: wt, hyp: at)
                mm.werAppleVsWhisper = wer
                allWerAW.append(wer)
            }

            // Tie-break (needs all three).
            if let at = aToks, let wt = wToks, let rt = rToks,
               let aw = inputs.apple?.words, let ww = inputs.whisper?.words,
               let rw = inputs.reference?.words
            {
                let tb = TieBreak.analyze(
                    appleTokens: at, whisperTokens: wt, refTokens: rt,
                    appleWords: aw, whisperWords: ww, refWords: rw
                )
                mm.tieBreakCounts = tb.counts
                mm.tieBreakRegions = tb.regions
                // Tag regions with meetingID for the overall sample.
                let taggedRegions = tb.regions.map { r -> DisagreementRegion in
                    var tagged = r
                    tagged.meetingID = inputs.meetingID
                    return tagged
                }
                allTieBreakRegions.append(contentsOf: taggedRegions)
                for (k, v) in tb.counts.byRegion { overallTBByRegion[k, default: 0] += v }
                for (k, v) in tb.counts.byTokens { overallTBByTokens[k, default: 0] += v }
            }

            // Flags.
            var flags: [MeetingFlag] = []
            if let f = Flags.checkWERRatio(
                appleWER: mm.werAppleVsRef?.wer,
                whisperWER: mm.werWhisperVsRef?.wer
            ) { flags.append(f) }
            let transcriptsForFlags: [(EngineID, EngineTranscript)] = [
                inputs.apple.map { (.apple, $0) },
                inputs.whisper.map { (.whisper, $0) },
                inputs.reference.map { (.reference, $0) },
            ].compactMap { $0 }
            flags.append(contentsOf: Flags.checkDroppedStretches(
                transcripts: transcriptsForFlags,
                audioDuration: inputs.meta.durationSeconds
            ))
            let emptyCheck: [(EngineID, EngineTranscript?)] = [
                (.apple, inputs.apple),
                (.whisper, inputs.whisper),
                (.reference, inputs.reference),
            ]
            flags.append(contentsOf: Flags.checkEmpty(transcripts: emptyCheck))
            mm.flags = flags.map { describeFlag($0) }

            // Text quality.
            if let a = inputs.apple {
                mm.textQualityApple = TextQuality.compute(displayText: a.displayText, words: a.words)
            }
            if let w = inputs.whisper {
                mm.textQualityWhisper = TextQuality.compute(displayText: w.displayText, words: w.words)
            }
            if let r = inputs.reference {
                mm.textQualityReference = TextQuality.compute(displayText: r.displayText, words: r.words)
            }

            // Timing — collect raw deltas for overall aggregation.
            if let at = aToks, let wt = wToks, let aw = inputs.apple?.words, let ww = inputs.whisper?.words {
                let aTexts = at.map(\.text)
                let wTexts = wt.map(\.text)
                let ops = Aligner.align(wTexts, aTexts)
                let (ss, es) = Timing.compute(opsXY: ops, xTokens: wt, yTokens: at,
                                               xWords: ww, yWords: aw)
                mm.timingAppleVsWhisper = TimingResult(engineX: .whisper, engineY: .apple,
                                                       startStats: ss, endStats: es)
                collectTimingDeltas(ops: ops, xTokens: wt, yTokens: at, xWords: ww, yWords: aw,
                                    startDeltas: &allStartDeltasAW, endDeltas: &allEndDeltasAW)
            }
            if let at = aToks, let rt = rToks, let aw = inputs.apple?.words,
               let rw = inputs.reference?.words, inputs.reference?.hasWordTimes == true
            {
                let aTexts = at.map(\.text)
                let rTexts = rt.map(\.text)
                let ops = Aligner.align(rTexts, aTexts)
                let (ss, es) = Timing.compute(opsXY: ops, xTokens: rt, yTokens: at,
                                               xWords: rw, yWords: aw)
                mm.timingAppleVsRef = TimingResult(engineX: .reference, engineY: .apple,
                                                    startStats: ss, endStats: es)
                collectTimingDeltas(ops: ops, xTokens: rt, yTokens: at, xWords: rw, yWords: aw,
                                    startDeltas: &allStartDeltasAR, endDeltas: &allEndDeltasAR)
            }
            if let wt = wToks, let rt = rToks, let ww = inputs.whisper?.words,
               let rw = inputs.reference?.words, inputs.reference?.hasWordTimes == true
            {
                let wTexts = wt.map(\.text)
                let rTexts = rt.map(\.text)
                let ops = Aligner.align(rTexts, wTexts)
                let (ss, es) = Timing.compute(opsXY: ops, xTokens: rt, yTokens: wt,
                                               xWords: rw, yWords: ww)
                mm.timingWhisperVsRef = TimingResult(engineX: .reference, engineY: .whisper,
                                                      startStats: ss, endStats: es)
                collectTimingDeltas(ops: ops, xTokens: rt, yTokens: wt, xWords: rw, yWords: ww,
                                    startDeltas: &allStartDeltasWR, endDeltas: &allEndDeltasWR)
            }

            // Speaker alignment — compute once, reuse for metrics and transcript writing.
            if let dia = inputs.diarizationOutput?.diarization {
                let diaResult = dia.rebuild()

                var appleAligned: AlignedTranscript?
                var whisperAligned: AlignedTranscript?
                var refAligned: AlignedTranscript?

                if let apple = inputs.apple {
                    let aligned = SpeakerAlignment.align(
                        apple, whisperRaw: nil,
                        diarization: diaResult,
                        audioDuration: inputs.meta.durationSeconds
                    )
                    appleAligned = aligned
                    mm.segmentStatsApple = SpeakerMetrics.segmentStats(aligned)
                    mm.droppedUntimedApple = aligned.droppedUntimedWords
                }

                if let whisper = inputs.whisper {
                    let aligned = SpeakerAlignment.align(
                        whisper, whisperRaw: inputs.whisperRaw,
                        diarization: diaResult,
                        audioDuration: inputs.meta.durationSeconds
                    )
                    whisperAligned = aligned
                    mm.segmentStatsWhisper = SpeakerMetrics.segmentStats(aligned)
                    mm.droppedUntimedWhisper = aligned.droppedUntimedWords
                }

                if let ref = inputs.reference, ref.hasWordTimes {
                    let aligned = SpeakerAlignment.align(
                        ref, whisperRaw: nil,
                        diarization: diaResult,
                        audioDuration: inputs.meta.durationSeconds
                    )
                    refAligned = aligned
                    mm.segmentStatsReference = SpeakerMetrics.segmentStats(aligned)
                    mm.droppedUntimedReference = aligned.droppedUntimedWords
                }

                // Diarization boundaries for disagreement sample.
                var diaBoundaries: [Double] = []
                for seg in diaResult.segments {
                    diaBoundaries.append(Double(seg.startTime))
                    diaBoundaries.append(Double(seg.endTime))
                }

                // Speaker agreement A vs W.
                if let aAligned = appleAligned, let wAligned = whisperAligned {
                    let (timeAgree, covA, covW) = SpeakerMetrics.timeAgreement(
                        a: aAligned, b: wAligned,
                        audioDuration: inputs.meta.durationSeconds
                    )
                    let at2 = Normalizer.tokens(for: aAligned.words.map(\.word))
                    let wt2 = Normalizer.tokens(for: wAligned.words.map(\.word))
                    let aTexts2 = at2.map(\.text)
                    let wTexts2 = wt2.map(\.text)
                    let opsAW2 = Aligner.align(wTexts2, aTexts2)
                    let wordAgree = SpeakerMetrics.wordAgreement(
                        opsAB: opsAW2, aTokens: wt2, bTokens: at2,
                        aWords: wAligned.words, bWords: aAligned.words
                    )
                    mm.speakerAgreementAW = SpeakerAgreement(
                        timeAgreement: timeAgree, coverageA: covA,
                        coverageB: covW, wordAgreement: wordAgree
                    )

                    mm.speakerDisagreementSample = SpeakerMetrics.disagreementSample(
                        opsAB: opsAW2, aTokens: wt2, bTokens: at2,
                        aWords: wAligned.words, bWords: aAligned.words,
                        aEngine: wAligned.words.map(\.word), bEngine: aAligned.words.map(\.word),
                        diarizationBoundaries: diaBoundaries
                    )
                }

                // Speaker agreement A vs R.
                if let aAligned = appleAligned, let rAligned = refAligned {
                    let (timeAgree, covA, covR) = SpeakerMetrics.timeAgreement(
                        a: aAligned, b: rAligned,
                        audioDuration: inputs.meta.durationSeconds
                    )
                    let at2 = Normalizer.tokens(for: aAligned.words.map(\.word))
                    let rt2 = Normalizer.tokens(for: rAligned.words.map(\.word))
                    let aTexts2 = at2.map(\.text)
                    let rTexts2 = rt2.map(\.text)
                    let opsAR2 = Aligner.align(rTexts2, aTexts2)
                    let wordAgree = SpeakerMetrics.wordAgreement(
                        opsAB: opsAR2, aTokens: rt2, bTokens: at2,
                        aWords: rAligned.words, bWords: aAligned.words
                    )
                    mm.speakerAgreementAR = SpeakerAgreement(
                        timeAgreement: timeAgree, coverageA: covA,
                        coverageB: covR, wordAgreement: wordAgree
                    )
                }

                // Speaker agreement W vs R.
                if let wAligned = whisperAligned, let rAligned = refAligned {
                    let (timeAgree, covW, covR) = SpeakerMetrics.timeAgreement(
                        a: wAligned, b: rAligned,
                        audioDuration: inputs.meta.durationSeconds
                    )
                    let wt2 = Normalizer.tokens(for: wAligned.words.map(\.word))
                    let rt2 = Normalizer.tokens(for: rAligned.words.map(\.word))
                    let wTexts2 = wt2.map(\.text)
                    let rTexts2 = rt2.map(\.text)
                    let opsWR2 = Aligner.align(rTexts2, wTexts2)
                    let wordAgree = SpeakerMetrics.wordAgreement(
                        opsAB: opsWR2, aTokens: rt2, bTokens: wt2,
                        aWords: rAligned.words, bWords: wAligned.words
                    )
                    mm.speakerAgreementWR = SpeakerAgreement(
                        timeAgreement: timeAgree, coverageA: covW,
                        coverageB: covR, wordAgreement: wordAgree
                    )
                }

                // Store aligned transcripts for transcript writing.
                allAlignments[inputs.meetingID] = MeetingAlignments(
                    appleAligned: appleAligned,
                    whisperAligned: whisperAligned,
                    referenceAligned: refAligned
                )
            }

            allMeetingMetrics.append(mm)
            log.log("\(inputs.meetingID): done")
        }

        // Build report model.
        log.log("Building report...")
        var report = ReportModel(
            bundleID: manifest.bundleID.uuidString,
            meetings: allMeetingMetrics
        )

        // Machines.
        if let wo = meetingInputs.first(where: { $0.whisperOutput?.status == .completed })?.whisperOutput {
            let m = wo.machine
            report.homeMachine = ReportMachine(
                name: "home", chip: m.chip,
                memoryGB: Int(m.memoryBytes / 1_073_741_824),
                osVersion: m.osVersion
            )
        }
        if let session = runFile.sessions.first {
            let m = session.machine
            report.runnerMachine = ReportMachine(
                name: "runner", chip: m.chip,
                memoryGB: Int(m.memoryBytes / 1_073_741_824),
                osVersion: m.osVersion
            )
        }

        // Reference info.
        if let rs = meetingInputs.first(where: { $0.referenceStatus?.status == .completed })?.referenceStatus {
            report.referenceModel = rs.model
            report.referenceZDR = rs.zdr
        }
        let totalCost = meetingInputs.compactMap { $0.referenceStatus?.totalCost }.reduce(0, +)
        if totalCost > 0 { report.referenceTotalCost = totalCost }

        // Pooled WER.
        if !allWerAR.isEmpty { report.pooledWerAppleVsRef = WER.pool(allWerAR) }
        if !allWerWR.isEmpty { report.pooledWerWhisperVsRef = WER.pool(allWerWR) }
        if !allWerAW.isEmpty { report.pooledWerAppleVsWhisper = WER.pool(allWerAW) }

        // Overall tie-break.
        if !overallTBByRegion.isEmpty {
            report.overallTieBreakCounts = TieBreakCounts(byRegion: overallTBByRegion, byTokens: overallTBByTokens)
            report.tieBreakSample = TieBreak.sample(allTieBreakRegions)
        }

        // Median RTF.
        let appleRTFs = allMeetingMetrics.compactMap(\.appleRTF)
        let whisperRTFs = allMeetingMetrics.compactMap(\.whisperRTF)
        if !appleRTFs.isEmpty { report.medianAppleRTF = median(appleRTFs.sorted()) }
        if !whisperRTFs.isEmpty { report.medianWhisperRTF = median(whisperRTFs.sorted()) }

        // Overall timing (from pooled raw deltas).
        if !allStartDeltasAW.isEmpty {
            report.overallTimingAW = TimingResult(
                engineX: .whisper, engineY: .apple,
                startStats: Timing.computeStats(allStartDeltasAW),
                endStats: Timing.computeStats(allEndDeltasAW)
            )
        }
        if !allStartDeltasAR.isEmpty {
            report.overallTimingAR = TimingResult(
                engineX: .reference, engineY: .apple,
                startStats: Timing.computeStats(allStartDeltasAR),
                endStats: Timing.computeStats(allEndDeltasAR)
            )
        }
        if !allStartDeltasWR.isEmpty {
            report.overallTimingWR = TimingResult(
                engineX: .reference, engineY: .whisper,
                startStats: Timing.computeStats(allStartDeltasWR),
                endStats: Timing.computeStats(allEndDeltasWR)
            )
        }

        // Overall speaker agreement (average).
        report.overallSpeakerAgreementAW = averageSpeakerAgreement(
            allMeetingMetrics.compactMap(\.speakerAgreementAW)
        )
        report.overallSpeakerAgreementAR = averageSpeakerAgreement(
            allMeetingMetrics.compactMap(\.speakerAgreementAR)
        )
        report.overallSpeakerAgreementWR = averageSpeakerAgreement(
            allMeetingMetrics.compactMap(\.speakerAgreementWR)
        )

        report.errors = errors

        return PipelineResult(report: report, alignments: allAlignments)
    }

    /// Write report outputs to disk, using cached alignments from the pipeline run.
    public static func writeOutputs(
        result: PipelineResult,
        meetingInputs: [MeetingInputs],
        outputDir: URL
    ) throws {
        let fm = FileManager.default
        if fm.fileExists(atPath: outputDir.path) {
            try fm.removeItem(at: outputDir)
        }
        try fm.createDirectory(at: outputDir, withIntermediateDirectories: true)

        // metrics.json
        try JSONFiles.write(result.report, to: outputDir.appendingPathComponent("metrics.json"))

        // report.md
        let markdown = MarkdownRenderer.render(result.report)
        try markdown.write(
            to: outputDir.appendingPathComponent("report.md"),
            atomically: true, encoding: .utf8
        )

        // Transcript files.
        for inputs in meetingInputs {
            if let a = inputs.apple {
                try TranscriptWriter.writePlainText(
                    displayText: a.displayText, engine: .apple,
                    meetingID: inputs.meetingID, outputDir: outputDir
                )
            }
            if let w = inputs.whisper {
                try TranscriptWriter.writePlainText(
                    displayText: w.displayText, engine: .whisper,
                    meetingID: inputs.meetingID, outputDir: outputDir
                )
            }
            if let r = inputs.reference {
                try TranscriptWriter.writePlainText(
                    displayText: r.displayText, engine: .reference,
                    meetingID: inputs.meetingID, outputDir: outputDir
                )
            }

            // Speaker-annotated transcripts from cached alignments (no recomputation).
            let cached = result.alignments[inputs.meetingID]
            if let aligned = cached?.appleAligned {
                try TranscriptWriter.writeSpeakerAnnotated(
                    aligned: aligned, meetingID: inputs.meetingID, outputDir: outputDir
                )
            }
            if let aligned = cached?.whisperAligned {
                try TranscriptWriter.writeSpeakerAnnotated(
                    aligned: aligned, meetingID: inputs.meetingID, outputDir: outputDir
                )
            }
            if let aligned = cached?.referenceAligned {
                try TranscriptWriter.writeSpeakerAnnotated(
                    aligned: aligned, meetingID: inputs.meetingID, outputDir: outputDir
                )
            }
        }
    }

    // MARK: - Helpers

    public static func describeFlag(_ flag: MeetingFlag) -> String {
        switch flag {
        case let .werRatio(a, w):
            return "WER ratio: Apple \(String(format: "%.1f%%", a * 100)) vs Whisper \(String(format: "%.1f%%", w * 100))"
        case let .droppedStretch(engine, start, end):
            return "\(engine.rawValue) dropped \(String(format: "%.0f", end - start))s (\(String(format: "%.0f", start))-\(String(format: "%.0f", end))s)"
        case let .emptyResult(engine):
            return "\(engine.rawValue) returned no words"
        }
    }

    static func median(_ sorted: [Double]) -> Double? {
        guard !sorted.isEmpty else { return nil }
        return sorted[sorted.count / 2]
    }

    /// Collect raw timing deltas from alignment ops for aggregation.
    static func collectTimingDeltas(
        ops: [EditOp],
        xTokens: [NormToken], yTokens: [NormToken],
        xWords: [EngineWord], yWords: [EngineWord],
        startDeltas: inout [Double], endDeltas: inout [Double]
    ) {
        var seen = Set<String>()
        for op in ops {
            guard case .match(let xi, let yi) = op else { continue }
            let xSrc = xTokens[xi].sourceIndex
            let ySrc = yTokens[yi].sourceIndex
            let key = "\(xSrc)-\(ySrc)"
            guard seen.insert(key).inserted else { continue }

            let xw = xWords[xSrc]
            let yw = yWords[ySrc]
            if let xs = xw.start, let ys = yw.start {
                startDeltas.append(ys - xs)
            }
            if let xe = xw.end, let ye = yw.end {
                endDeltas.append(ye - xe)
            }
        }
    }

    /// Collect error descriptions from engine outputs.
    static func collectErrors(inputs: MeetingInputs, mm: MeetingMetrics, into errors: inout [String]) {
        let mid = inputs.meetingID
        if let appleResult = inputs.appleResult, appleResult.status == .failed {
            let desc = appleResult.error?.description ?? "unknown"
            errors.append("\(mid): Apple failed — \(desc)")
        }
        if let whisperOut = inputs.whisperOutput, whisperOut.status == .failed {
            let desc = whisperOut.error?.description ?? "unknown"
            errors.append("\(mid): Whisper failed — \(desc)")
        }
        if let diaOut = inputs.diarizationOutput, diaOut.status == .failed {
            let desc = diaOut.error?.description ?? "unknown"
            errors.append("\(mid): Diarization failed — \(desc)")
        }
        if let refStatus = inputs.referenceStatus, refStatus.status == .failed {
            let desc = refStatus.error?.description ?? "unknown"
            errors.append("\(mid): Reference failed — \(desc)")
        }
    }

    /// Average SpeakerAgreement across meetings (time and word agreement only).
    static func averageSpeakerAgreement(_ agreements: [SpeakerAgreement]) -> SpeakerAgreement? {
        guard !agreements.isEmpty else { return nil }
        let timeAgrees = agreements.compactMap(\.timeAgreement)
        let wordAgrees = agreements.compactMap(\.wordAgreement)
        return SpeakerAgreement(
            timeAgreement: timeAgrees.isEmpty ? nil : timeAgrees.reduce(0, +) / Double(timeAgrees.count),
            coverageA: nil, coverageB: nil,
            wordAgreement: wordAgrees.isEmpty ? nil : wordAgrees.reduce(0, +) / Double(wordAgrees.count)
        )
    }
}
