import ArgumentParser
import Foundation
import STTLabAnalysis
import STTLabCore
import STTLabHome

struct AnalyzeCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "analyze",
        abstract: "Analyze home + runner results and generate the report",
        subcommands: [AnalyzePrepCommand.self, AnalyzeFinalCommand.self]
    )
}

// MARK: - analyze prep

struct AnalyzePrepCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "prep",
        abstract: "Compute disagreement regions and write per-meeting reports for LLM judging"
    )

    @OptionGroup var workspaceOpt: WorkspaceOption

    @Option(name: .long, help: "Path to the runner results directory")
    var results: String

    @Option(name: .long, help: "Analysis directory (default: <workspace>/analysis)")
    var analysisDir: String?

    func run() async throws {
        let ws = workspaceOpt.workspaceURL
        let log = workspaceOpt.openLog(command: "analyze-prep")
        let resultsURL = URL(fileURLWithPath: (results as NSString).expandingTildeInPath)
        let analysisDirURL: URL
        if let p = analysisDir {
            analysisDirURL = URL(fileURLWithPath: (p as NSString).expandingTildeInPath)
        } else {
            analysisDirURL = ws.appendingPathComponent("analysis")
        }

        log.log("Loading workspace: \(ws.path)")
        log.log("Results: \(resultsURL.path)")
        log.log("Analysis dir: \(analysisDirURL.path)")

        // Load manifest and validate.
        let bundleDir = ws.appendingPathComponent("bundle")
        let bundle = try BundleLoader.load(from: bundleDir)

        let runFileURL = resultsURL.appendingPathComponent("run.json")
        let runFile: RunFile = try JSONFiles.read(from: runFileURL)
        for session in runFile.sessions {
            guard session.bundleID == bundle.manifest.bundleID else {
                log.log("ERROR: Results bundle ID \(session.bundleID) does not match "
                    + "workspace bundle ID \(bundle.manifest.bundleID)")
                throw ExitCode(1)
            }
        }

        // Load meeting inputs.
        log.log("Loading meeting data...")
        let meetingInputs = try AnalyzeInputs.load(
            workspace: ws,
            resultsDir: resultsURL,
            manifest: bundle.manifest,
            metas: bundle.metas
        )

        // Run the prep pipeline.
        let prepResult = try AnalyzePrepPipeline.run(
            meetingInputs: meetingInputs,
            analysisDir: analysisDirURL,
            log: log
        )

        // Print summary.
        log.log("")
        log.log("Prep complete:")
        log.log("  Meetings written: \(prepResult.meetingsWritten)")
        for (mid, count) in prepResult.regionsPerMeeting.sorted(by: { $0.key < $1.key }) {
            log.log("  \(mid): \(count) regions")
        }
        if !prepResult.meetingsLackingReference.isEmpty {
            log.log("  Meetings lacking reference: \(prepResult.meetingsLackingReference.joined(separator: ", "))")
        }
        if !prepResult.staleDecisions.isEmpty {
            log.log("  WARNING: Stale decision files: \(prepResult.staleDecisions.joined(separator: ", "))")
        }
        log.log("  Analysis dir: \(analysisDirURL.path)")
    }
}

// MARK: - analyze final

struct AnalyzeFinalCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "final",
        abstract: "Generate the full report using LLM decisions"
    )

    @OptionGroup var workspaceOpt: WorkspaceOption

    @Option(name: .long, help: "Path to the runner results directory")
    var results: String

    @Option(name: .long, help: "Analysis directory (default: <workspace>/analysis)")
    var analysisDir: String?

    @Option(name: .long, help: "Output directory (default: <workspace>/report)")
    var out: String?

    func run() async throws {
        let ws = workspaceOpt.workspaceURL
        let log = workspaceOpt.openLog(command: "analyze-final")
        let resultsURL = URL(fileURLWithPath: (results as NSString).expandingTildeInPath)
        let analysisDirURL: URL
        if let p = analysisDir {
            analysisDirURL = URL(fileURLWithPath: (p as NSString).expandingTildeInPath)
        } else {
            analysisDirURL = ws.appendingPathComponent("analysis")
        }
        let outputDir: URL
        if let outPath = out {
            outputDir = URL(fileURLWithPath: (outPath as NSString).expandingTildeInPath)
        } else {
            outputDir = ws.appendingPathComponent("report")
        }

        log.log("Loading workspace: \(ws.path)")
        log.log("Results: \(resultsURL.path)")
        log.log("Analysis dir: \(analysisDirURL.path)")
        log.log("Output: \(outputDir.path)")

        // Load manifest and validate.
        let bundleDir = ws.appendingPathComponent("bundle")
        let bundle = try BundleLoader.load(from: bundleDir)

        let runFileURL = resultsURL.appendingPathComponent("run.json")
        let runFile: RunFile = try JSONFiles.read(from: runFileURL)
        for session in runFile.sessions {
            guard session.bundleID == bundle.manifest.bundleID else {
                log.log("ERROR: Results bundle ID \(session.bundleID) does not match "
                    + "workspace bundle ID \(bundle.manifest.bundleID)")
                throw ExitCode(1)
            }
        }

        // Load meeting inputs.
        log.log("Loading meeting data...")
        let meetingInputs = try AnalyzeInputs.load(
            workspace: ws,
            resultsDir: resultsURL,
            manifest: bundle.manifest,
            metas: bundle.metas
        )

        // Run the final pipeline.
        try AnalyzeFinalPipeline.run(
            meetingInputs: meetingInputs,
            manifest: bundle.manifest,
            runFile: runFile,
            analysisDir: analysisDirURL,
            outputDir: outputDir,
            log: log
        )

        log.log("  report.md")
        log.log("  metrics.json")
        log.log("  transcripts/")
    }
}
