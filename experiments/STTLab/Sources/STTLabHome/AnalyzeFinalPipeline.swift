import Foundation
import STTLabAnalysis
import STTLabCore

/// The `analyze final` pipeline: reads decision files, runs the full metrics
/// pipeline, overlays LLM decisions onto the report, and writes outputs.
public enum AnalyzeFinalPipeline {

    /// Run the final pipeline.
    ///
    /// - Parameters:
    ///   - meetingInputs: Loaded meeting inputs.
    ///   - manifest: The bundle manifest.
    ///   - runFile: The runner's run.json.
    ///   - analysisDir: Directory with per-meeting analysis data.
    ///   - outputDir: Where to write the report.
    ///   - log: Logger.
    public static func run(
        meetingInputs: [MeetingInputs],
        manifest: BundleManifest,
        runFile: RunFile,
        analysisDir: URL,
        outputDir: URL,
        log: RunLog
    ) throws {
        // Run the core metrics pipeline (WER, timing, speakers, etc.).
        log.log("Computing metrics...")
        var result = AnalyzePipeline.run(
            meetingInputs: meetingInputs,
            manifest: manifest,
            runFile: runFile,
            log: log
        )

        // Load disagreement reports and decisions per meeting.
        log.log("Loading LLM decisions...")
        var meetingDecisionResults: [MeetingDecisionResult] = []

        for inputs in meetingInputs {
            let mid = inputs.meetingID
            let meetingDir = analysisDir.appendingPathComponent(mid)
            let reportURL = meetingDir.appendingPathComponent("disagreement_report.json")
            let decisionURL = meetingDir.appendingPathComponent("disagreement_decision.json")

            // Load the report file (written by prep).
            guard let reportData = try? Data(contentsOf: reportURL),
                  let reportFile = try? JSONDecoder().decode(
                      DisagreementReportFile.self, from: reportData
                  )
            else {
                log.log("\(mid): no disagreement report — skipping LLM decisions")
                continue
            }

            // Load decision file (written by LLM, may not exist).
            let decisionData = try? Data(contentsOf: decisionURL)

            let decisionResult = DecisionParser.parse(
                decisionData: decisionData,
                reportEntries: reportFile.disagreements,
                reportFingerprint: reportFile.reportFingerprint,
                meetingID: mid
            )

            meetingDecisionResults.append(decisionResult)

            for warning in decisionResult.warnings {
                log.log("WARNING: \(warning)")
            }

            if decisionResult.judged {
                let dCount = decisionResult.decisions.count
                let undecided = decisionResult.decisions.filter { $0.decision == .undecided }.count
                log.log("\(mid): loaded \(dCount - undecided)/\(dCount) decisions")
            } else {
                log.log("\(mid): not judged")
            }
        }

        // Aggregate LLM decisions.
        if !meetingDecisionResults.isEmpty {
            let (overall, perMeeting) = LLMJudgementAggregator.aggregate(
                meetingResults: meetingDecisionResults
            )
            result.report.llmJudgement = overall
            result.report.llmPerMeeting = perMeeting

            // Add LLM caveats.
            result.report.caveats.append(contentsOf: overall.caveats)

            // Set per-meeting LLM counts.
            for (idx, mm) in result.report.meetings.enumerated() {
                result.report.meetings[idx].llmCounts = perMeeting[mm.meetingID]
            }
        }

        // Write outputs.
        try AnalyzePipeline.writeOutputs(
            result: result,
            meetingInputs: meetingInputs,
            outputDir: outputDir
        )

        log.log("Report written to: \(outputDir.path)")
    }
}
