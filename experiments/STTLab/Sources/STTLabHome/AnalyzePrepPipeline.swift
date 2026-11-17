import Foundation
import STTLabAnalysis
import STTLabCore

/// The `analyze prep` pipeline: loads inputs, computes disagreement regions
/// per meeting, and writes `disagreement_report.json` for each meeting that
/// has both Apple and Whisper output.
public enum AnalyzePrepPipeline {

    /// Result of the prep step.
    public struct PrepResult: Sendable {
        public var meetingsWritten: Int
        public var regionsPerMeeting: [String: Int]
        public var meetingsLackingReference: [String]
        public var staleDecisions: [String]
        public var analysisDir: URL
    }

    /// Run the prep pipeline.
    ///
    /// - Parameters:
    ///   - meetingInputs: Loaded meeting inputs.
    ///   - analysisDir: Directory for per-meeting analysis output.
    ///   - log: Logger.
    /// - Returns: A summary of what was written.
    public static func run(
        meetingInputs: [MeetingInputs],
        analysisDir: URL,
        log: RunLog
    ) throws -> PrepResult {
        let fm = FileManager.default

        var meetingsWritten = 0
        var regionsPerMeeting: [String: Int] = [:]
        var meetingsLackingReference: [String] = []
        var staleDecisions: [String] = []

        for inputs in meetingInputs {
            let mid = inputs.meetingID

            // Need both Apple and Whisper for disagreement analysis.
            guard let apple = inputs.apple, let whisper = inputs.whisper else {
                log.log("\(mid): skipped (need both Apple and Whisper)")
                continue
            }

            let hasReference = inputs.reference != nil
            if !hasReference {
                meetingsLackingReference.append(mid)
            }

            // Normalize tokens.
            let aToks = Normalizer.tokens(for: apple.words)
            let wToks = Normalizer.tokens(for: whisper.words)

            // Need reference tokens for tie-break (but regions need only A vs W).
            let rToks: [NormToken]
            let refWords: [EngineWord]
            if let ref = inputs.reference {
                rToks = Normalizer.tokens(for: ref.words)
                refWords = ref.words
            } else {
                // Without reference we can still compute A-vs-W regions,
                // but they have no reference text.
                rToks = []
                refWords = []
            }

            // Compute disagreement regions.
            let regions: [DisagreementRegion]
            if !rToks.isEmpty {
                let tb = TieBreak.analyze(
                    appleTokens: aToks, whisperTokens: wToks, refTokens: rToks,
                    appleWords: apple.words, whisperWords: whisper.words, refWords: refWords
                )
                regions = tb.regions
            } else {
                // Without reference, build regions from A-vs-W alignment only.
                // Use empty ref tokens -> regions will have empty ref text.
                let tb = TieBreak.analyze(
                    appleTokens: aToks, whisperTokens: wToks, refTokens: [],
                    appleWords: apple.words, whisperWords: whisper.words, refWords: []
                )
                regions = tb.regions
            }

            // Build report entries.
            let entries = DisagreementReportBuilder.buildEntries(
                regions: regions,
                meetingID: mid,
                hasReference: hasReference,
                referenceWords: inputs.reference?.words,
                appleWords: apple.words,
                whisperWords: whisper.words
            )

            // Build and write the report file.
            let reportFile = DisagreementReportFile(
                meetingId: mid,
                hasReference: hasReference,
                durationSeconds: inputs.meta.durationSeconds,
                disagreements: entries
            )

            let meetingDir = analysisDir.appendingPathComponent(mid)
            try fm.createDirectory(at: meetingDir, withIntermediateDirectories: true)

            let reportURL = meetingDir.appendingPathComponent("disagreement_report.json")
            try JSONFiles.write(reportFile, to: reportURL)

            // Check if an existing decision file's fingerprint still matches.
            let decisionURL = meetingDir.appendingPathComponent("disagreement_decision.json")
            if fm.fileExists(atPath: decisionURL.path) {
                if let decisionData = try? Data(contentsOf: decisionURL),
                   let decisionFile = try? JSONDecoder().decode(
                       DisagreementDecisionFile.self, from: decisionData
                   )
                {
                    if decisionFile.reportFingerprint != reportFile.reportFingerprint {
                        staleDecisions.append(mid)
                        log.log("WARNING: \(mid): existing decision file fingerprint does not match new report")
                    }
                }
                // Never delete or overwrite the decision file.
            }

            meetingsWritten += 1
            regionsPerMeeting[mid] = entries.count
            log.log("\(mid): wrote \(entries.count) disagreement regions")
        }

        return PrepResult(
            meetingsWritten: meetingsWritten,
            regionsPerMeeting: regionsPerMeeting,
            meetingsLackingReference: meetingsLackingReference,
            staleDecisions: staleDecisions,
            analysisDir: analysisDir
        )
    }
}
