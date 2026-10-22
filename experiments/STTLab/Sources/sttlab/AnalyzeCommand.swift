import ArgumentParser
import Foundation
import STTLabAnalysis
import STTLabCore
import STTLabHome

struct AnalyzeCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "analyze",
        abstract: "Analyze home + runner results and generate the report"
    )

    @OptionGroup var workspaceOpt: WorkspaceOption

    @Option(name: .long, help: "Path to the runner results directory")
    var results: String

    @Option(name: .long, help: "Output directory (default: <workspace>/report)")
    var out: String?

    func run() async throws {
        let ws = workspaceOpt.workspaceURL
        let log = workspaceOpt.openLog(command: "analyze")
        let resultsURL = URL(fileURLWithPath: (results as NSString).expandingTildeInPath)
        let outputDir: URL
        if let outPath = out {
            outputDir = URL(fileURLWithPath: (outPath as NSString).expandingTildeInPath)
        } else {
            outputDir = ws.appendingPathComponent("report")
        }

        log.log("Loading workspace: \(ws.path)")
        log.log("Results: \(resultsURL.path)")
        log.log("Output: \(outputDir.path)")

        // Load manifest and validate.
        let bundleDir = ws.appendingPathComponent("bundle")
        let bundle = try BundleLoader.load(from: bundleDir)

        // Validate runner results match the bundle.
        let runFileURL = resultsURL.appendingPathComponent("run.json")
        let runFile: RunFile = try JSONFiles.read(from: runFileURL)
        for session in runFile.sessions {
            guard session.bundleID == bundle.manifest.bundleID else {
                log.log("ERROR: Results bundle ID \(session.bundleID) does not match "
                    + "workspace bundle ID \(bundle.manifest.bundleID)")
                throw ExitCode(1)
            }
        }

        // Load all meeting inputs.
        log.log("Loading meeting data...")
        let meetingInputs = try AnalyzeInputs.load(
            workspace: ws,
            resultsDir: resultsURL,
            manifest: bundle.manifest,
            metas: bundle.metas
        )

        // Run the pipeline.
        log.log("Computing metrics...")
        let result = AnalyzePipeline.run(
            meetingInputs: meetingInputs,
            manifest: bundle.manifest,
            runFile: runFile,
            log: log
        )

        // Write outputs.
        try AnalyzePipeline.writeOutputs(
            result: result,
            meetingInputs: meetingInputs,
            outputDir: outputDir
        )

        log.log("Report written to: \(outputDir.path)")
        log.log("  report.md")
        log.log("  metrics.json")
        log.log("  transcripts/")
    }
}
