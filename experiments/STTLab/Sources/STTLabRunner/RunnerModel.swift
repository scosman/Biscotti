import AppKit
import Foundation
import STTLabCore

/// Per-meeting status displayed in the UI table.
enum MeetingStatus: Sendable {
    case pending
    case running(percent: Int)
    case completed
    case skipped
    case failed(String)
    case unsupportedLocale
}

/// A row in the meetings table.
struct MeetingRow: Identifiable, Sendable {
    let id: String // meetingID
    let durationSeconds: Double
    let locale: String
    var status: MeetingStatus
}

/// Observable model that drives the runner UI.
@MainActor
@Observable
final class RunnerModel {
    // Bundle
    var bundleURL: URL?
    var bundleInfo: String = ""
    var meetingRows: [MeetingRow] = []
    var resultsURL: URL?

    // Session state
    var isRunning = false
    var forceRerun = false
    var progressText = ""
    var overallProgress: Double = 0

    // System info
    var systemInfoText: String = ""
    var speechAvailable: Bool = false

    // Log
    var logLines: [String] = []
    private let maxLogLines = 200

    // Internals (not displayed)
    private var runnerJob: RunnerJob?
    private var activity: NSObjectProtocol?

    init() {
        let osVersion = ProcessInfo.processInfo.operatingSystemVersionString
        systemInfoText = "macOS \(osVersion)"
        if #available(macOS 26, *) {
            // Availability is checked at runtime once the user loads a bundle
            speechAvailable = true
            systemInfoText += " | SpeechTranscriber: checking..."
        } else {
            speechAvailable = false
            systemInfoText += " | SpeechTranscriber: unavailable (needs macOS 26+)"
        }

        // Check availability asynchronously
        Task {
            await checkAvailability()
        }
    }

    private func checkAvailability() async {
        if #available(macOS 26, *) {
            let available = AppleTranscription.isAvailable
            speechAvailable = available
            let osVersion = ProcessInfo.processInfo.operatingSystemVersionString
            systemInfoText = "macOS \(osVersion) | SpeechTranscriber: \(available ? "yes" : "no")"
        }
    }

    // MARK: - Bundle loading

    func chooseBundle() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.message = "Select the STTLab bundle folder"
        panel.prompt = "Choose Bundle"

        guard panel.runModal() == .OK, let url = panel.url else { return }
        loadBundle(from: url)
    }

    func loadBundle(from url: URL) {
        do {
            let bundle = try BundleLoader.load(from: url)
            bundleURL = url

            // Default results folder: <bundle parent>/<bundle name>-results
            let bundleName = url.lastPathComponent
            let resultsDir = url.deletingLastPathComponent()
                .appendingPathComponent("\(bundleName)-results")
            resultsURL = resultsDir

            let totalHours = bundle.metas.reduce(0.0) { $0 + $1.durationSeconds } / 3600
            let shortID = bundle.manifest.bundleID.uuidString.prefix(8)
            bundleInfo = "Bundle \(shortID) | \(bundle.metas.count) meetings | \(String(format: "%.1f", totalHours)) hours"

            meetingRows = bundle.metas.map { meta in
                let existing = ResultsWriter.loadMeetingResult(
                    meetingID: meta.meetingID, resultsURL: resultsDir
                )
                let status: MeetingStatus
                if let existing {
                    switch existing.status {
                    case .completed: status = .completed
                    case .failed: status = .failed(existing.error?.description ?? "unknown")
                    case .unsupportedLocale: status = .unsupportedLocale
                    }
                } else {
                    status = .pending
                }
                return MeetingRow(
                    id: meta.meetingID,
                    durationSeconds: meta.durationSeconds,
                    locale: meta.appleLocale,
                    status: status
                )
            }
            appendLog("Loaded bundle from \(url.path)")
        } catch {
            bundleInfo = "Error: \(error.localizedDescription)"
            meetingRows = []
            appendLog("Failed to load bundle: \(error)")
        }
    }

    // MARK: - Run

    func startRun() {
        guard let bundleURL, let resultsURL, !isRunning else { return }

        isRunning = true
        progressText = "Starting..."
        overallProgress = 0

        // Reset pending rows
        for i in meetingRows.indices {
            if case .pending = meetingRows[i].status {
                // Keep pending
            } else if case .failed = meetingRows[i].status {
                meetingRows[i].status = .pending
            } else if forceRerun {
                meetingRows[i].status = .pending
            }
        }

        // Prevent sleep
        activity = ProcessInfo.processInfo.beginActivity(
            options: [.userInitiated, .idleSystemSleepDisabled],
            reason: "STTLabRunner transcribing meetings"
        )

        Task {
            await runSession(bundleURL: bundleURL, resultsURL: resultsURL)
        }
    }

    func stopAfterCurrent() {
        Task {
            await runnerJob?.requestStop()
        }
        appendLog("Stop requested -- will finish current meeting")
    }

    private func runSession(bundleURL: URL, resultsURL: URL) async {
        defer {
            isRunning = false
            runnerJob = nil
            if let act = activity { ProcessInfo.processInfo.endActivity(act); activity = nil }
        }

        do {
            try ResultsWriter.ensureResultsDir(at: resultsURL)
        } catch {
            appendLog("Could not create results directory: \(error)")
            return
        }

        let log = RunLog(
            logURL: ResultsWriter.logURL(resultsURL),
            echoToStdout: false,
            observer: { [weak self] line in
                Task { @MainActor in
                    self?.appendLog(line.trimmingCharacters(in: .newlines))
                }
            }
        )

        let job = RunnerJob(
            bundleURL: bundleURL,
            resultsURL: resultsURL,
            force: forceRerun,
            log: log,
            progress: { [weak self] p in
                Task { @MainActor in
                    self?.handleProgress(p)
                }
            }
        )
        runnerJob = job

        let bundle: LoadedBundle
        do {
            bundle = try await job.loadBundle()
        } catch {
            appendLog("Bundle load failed: \(error)")
            return
        }

        let summary = await job.run(bundle: bundle)

        // Update row statuses from disk
        for i in meetingRows.indices {
            let mid = meetingRows[i].id
            if let result = ResultsWriter.loadMeetingResult(meetingID: mid, resultsURL: resultsURL) {
                switch result.status {
                case .completed: meetingRows[i].status = .completed
                case .failed: meetingRows[i].status = .failed(result.error?.description ?? "unknown")
                case .unsupportedLocale: meetingRows[i].status = .unsupportedLocale
                }
            }
        }

        progressText = "Done -- \(summary.completed.count) completed, \(summary.failed.count) failed, \(summary.skipped.count) skipped"
        overallProgress = 1.0
    }

    private func handleProgress(_ p: RunnerProgress) {
        let percent = Int(p.meetingFraction * 100)
        progressText = "Meeting \(p.meetingIndex + 1) of \(p.meetingCount) -- \(p.meetingID) -- \(percent)% -- elapsed \(formatElapsed(p.elapsedSeconds))"
        overallProgress = (Double(p.meetingIndex) + p.meetingFraction) / Double(p.meetingCount)

        // Update the row status
        if let idx = meetingRows.firstIndex(where: { $0.id == p.meetingID }) {
            meetingRows[idx].status = .running(percent: percent)
        }
    }

    // MARK: - Reveal

    func revealResults() {
        guard let resultsURL else { return }
        NSWorkspace.shared.activateFileViewerSelecting([resultsURL])
    }

    // MARK: - Log

    private func appendLog(_ line: String) {
        logLines.append(line)
        if logLines.count > maxLogLines {
            logLines.removeFirst(logLines.count - maxLogLines)
        }
    }

    private func formatElapsed(_ seconds: Double) -> String {
        let mins = Int(seconds) / 60
        let secs = Int(seconds) % 60
        return String(format: "%d:%02d", mins, secs)
    }
}
