import Foundation
import STTLabCore

/// Headless CLI mode for the runner app.
/// Usage: STTLabRunner --cli <bundle> [--results <dir>] [--force]
enum RunnerCLI {
    static func main() -> Never {
        let args = CommandLine.arguments

        // Parse --cli <bundle> [--results <dir>] [--force]
        guard let cliIndex = args.firstIndex(of: "--cli"),
              cliIndex + 1 < args.count
        else {
            printUsage()
            exit(2)
        }

        let bundlePath = args[cliIndex + 1]
        let bundleURL = URL(fileURLWithPath: bundlePath)

        var resultsURL: URL?
        if let rIdx = args.firstIndex(of: "--results"), rIdx + 1 < args.count {
            resultsURL = URL(fileURLWithPath: args[rIdx + 1])
        }
        let force = args.contains("--force")

        // Default results path
        if resultsURL == nil {
            let bundleName = bundleURL.lastPathComponent
            resultsURL = bundleURL.deletingLastPathComponent()
                .appendingPathComponent("\(bundleName)-results")
        }

        guard let resultsURL else {
            fputs("Error: could not determine results path\n", stderr)
            exit(2)
        }

        // Create results dir
        do {
            try ResultsWriter.ensureResultsDir(at: resultsURL)
        } catch {
            fputs("Error: could not create results directory: \(error)\n", stderr)
            exit(2)
        }

        let log = RunLog(logURL: ResultsWriter.logURL(resultsURL), echoToStdout: true)

        let job = RunnerJob(
            bundleURL: bundleURL,
            resultsURL: resultsURL,
            force: force,
            log: log,
            progress: { p in
                let pct = Int(p.meetingFraction * 100)
                print("\r  \(p.meetingID) \(pct)%", terminator: "")
                fflush(stdout)
            }
        )

        // Launch async work, then exit from inside the Task.
        // The main thread stays alive via dispatchMain() so XPC / Speech can use it.
        Task {
            let bundle: LoadedBundle
            do {
                bundle = try await job.loadBundle()
            } catch {
                log.log("Bundle load failed: \(error)")
                exit(2)
            }

            log.log("Loaded bundle: \(bundle.manifest.meetings.count) meetings")
            let summary = await job.run(bundle: bundle)
            print() // Newline after progress

            log.log("Done: \(summary.completed.count) completed, \(summary.failed.count) failed, \(summary.skipped.count) skipped")
            log.log("Results at \(resultsURL.path)")

            if summary.speechUnavailable {
                exit(2)
            } else if !summary.failed.isEmpty {
                exit(1)
            } else {
                exit(0)
            }
        }

        // Keep the main thread alive for XPC / run-loop clients (Speech framework).
        dispatchMain()
    }

    // MARK: - Helpers

    private static func printUsage() {
        let usage = """
            Usage: STTLabRunner --cli <bundle-path> [--results <dir>] [--force]

            Arguments:
              <bundle-path>       Path to the STTLab bundle folder
              --results <dir>     Output directory (default: <bundle>-results)
              --force             Re-run completed meetings
            """
        fputs(usage + "\n", stderr)
    }
}
