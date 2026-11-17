import Foundation
import STTLabCore

/// Progress snapshot for one meeting within a runner session.
struct RunnerProgress: Sendable {
    var meetingIndex: Int
    var meetingCount: Int
    var meetingID: String
    var meetingFraction: Double
    var elapsedSeconds: Double
    var state: String
}

/// Summary of a completed runner session.
struct RunSummary: Sendable {
    var attempted: [String]
    var skipped: [String]
    var completed: [String]
    var failed: [String]
    var speechUnavailable: Bool
}

/// Errors specific to the runner job.
enum RunnerJobError: Error {
    case speechUnavailable
    case audioSHAMismatch(meetingID: String, expected: String, actual: String)
    case appleTimeout(meetingID: String, partialResults: Int)
}

/// Loads a bundle and runs Apple SpeechTranscriber on each meeting.
actor RunnerJob {
    private let bundleURL: URL
    private let resultsURL: URL
    private let force: Bool
    private let log: RunLog
    private let progress: @Sendable (RunnerProgress) -> Void
    private var stopRequested = false

    init(
        bundleURL: URL,
        resultsURL: URL,
        force: Bool,
        log: RunLog,
        progress: @escaping @Sendable (RunnerProgress) -> Void
    ) {
        self.bundleURL = bundleURL
        self.resultsURL = resultsURL
        self.force = force
        self.log = log
        self.progress = progress
    }

    /// Ask the job to stop after the current meeting finishes.
    func requestStop() {
        stopRequested = true
    }

    /// Load and validate the bundle.
    func loadBundle() throws -> LoadedBundle {
        try BundleLoader.load(from: bundleURL)
    }

    /// Run all meetings. Call `loadBundle()` first to get the manifest.
    func run(bundle: LoadedBundle) async -> RunSummary {
        let sessionStart = Date()
        var attempted: [String] = []
        var skipped: [String] = []
        var completed: [String] = []
        var failed: [String] = []

        let meetingCount = bundle.metas.count

        // Create/update run.json with a new session
        var runFile = ResultsWriter.loadRunFile(from: resultsURL)

        let speechAvailable = isSpeechAvailable()
        let supportedLocales = await querySupportedLocales()
        let installedLocales = await queryInstalledLocales()

        let session = RunnerSession(
            bundleID: bundle.manifest.bundleID,
            appVersion: toolVersion,
            machine: MachineInfo.current(),
            startedAt: sessionStart,
            speechTranscriberAvailable: speechAvailable,
            supportedLocales: supportedLocales,
            installedLocales: installedLocales,
            force: force
        )
        runFile.sessions.append(session)
        try? ResultsWriter.writeRunFile(runFile, to: resultsURL)

        guard speechAvailable else {
            log.log("SpeechTranscriber is not available on this system")
            return RunSummary(
                attempted: [], skipped: bundle.manifest.meetings,
                completed: [], failed: [], speechUnavailable: true
            )
        }

        for (index, meta) in bundle.metas.enumerated() {
            if stopRequested {
                log.log("Stop requested after meeting \(index)")
                break
            }

            let mid = meta.meetingID
            let existing = ResultsWriter.loadMeetingResult(meetingID: mid, resultsURL: resultsURL)

            guard RunnerResume.shouldRun(existing: existing, force: force) else {
                log.log("\(mid) already completed -- skipped")
                skipped.append(mid)
                continue
            }

            attempted.append(mid)
            let elapsed = Date().timeIntervalSince(sessionStart)
            progress(RunnerProgress(
                meetingIndex: index, meetingCount: meetingCount,
                meetingID: mid, meetingFraction: 0, elapsedSeconds: elapsed,
                state: "Checking audio integrity"
            ))

            // SHA-256 check (done per meeting because files are large)
            let audioURL = bundleURL
                .appendingPathComponent("meetings")
                .appendingPathComponent(mid)
                .appendingPathComponent(meta.audioFile)

            do {
                let actualSHA = try SHA256File.hex(url: audioURL)
                guard actualSHA == meta.audioSHA256 else {
                    let error = RunnerJobError.audioSHAMismatch(
                        meetingID: mid, expected: meta.audioSHA256, actual: actualSHA
                    )
                    let result = makeFailedResult(
                        meta: meta, bundleID: bundle.manifest.bundleID, error: error
                    )
                    try? ResultsWriter.writeMeetingResult(result, meetingID: mid, resultsURL: resultsURL)
                    log.log("\(mid) FAILED: audio file damaged in transfer (SHA mismatch)")
                    failed.append(mid)
                    continue
                }
            } catch {
                let result = makeFailedResult(
                    meta: meta, bundleID: bundle.manifest.bundleID, error: error
                )
                try? ResultsWriter.writeMeetingResult(result, meetingID: mid, resultsURL: resultsURL)
                log.log("\(mid) FAILED: could not read audio for SHA check: \(error)")
                failed.append(mid)
                continue
            }

            log.log("\(mid) starting transcription (\(index + 1)/\(meetingCount))")

            let result = await transcribeMeeting(
                meta: meta,
                audioURL: audioURL,
                bundleID: bundle.manifest.bundleID,
                meetingIndex: index,
                meetingCount: meetingCount,
                sessionStart: sessionStart
            )

            try? ResultsWriter.writeMeetingResult(result, meetingID: mid, resultsURL: resultsURL)

            switch result.status {
            case .completed:
                log.log("\(mid) completed (\(result.results.count) results)")
                completed.append(mid)
            case .failed:
                log.log("\(mid) FAILED: \(result.error?.description ?? "unknown error")")
                failed.append(mid)
            case .unsupportedLocale:
                log.log("\(mid) unsupported locale: \(meta.appleLocale)")
                completed.append(mid) // Not a failure; the result is informational
            }
        }

        // Update the session end time in run.json
        runFile = ResultsWriter.loadRunFile(from: resultsURL)
        if var last = runFile.sessions.last {
            last.endedAt = Date()
            last.meetingsAttempted = attempted
            last.meetingsSkipped = skipped
            runFile.sessions[runFile.sessions.count - 1] = last
        }
        try? ResultsWriter.writeRunFile(runFile, to: resultsURL)

        return RunSummary(
            attempted: attempted, skipped: skipped,
            completed: completed, failed: failed, speechUnavailable: false
        )
    }

    // MARK: - Private

    private func transcribeMeeting(
        meta: MeetingMeta,
        audioURL: URL,
        bundleID: UUID,
        meetingIndex: Int,
        meetingCount: Int,
        sessionStart: Date
    ) async -> AppleMeetingResult {
        if #available(macOS 26, *) {
            do {
                return try await AppleTranscription.transcribe(
                    meta: meta,
                    audioURL: audioURL,
                    bundleID: bundleID,
                    log: log
                ) { [progress] fraction in
                    let elapsed = Date().timeIntervalSince(sessionStart)
                    progress(RunnerProgress(
                        meetingIndex: meetingIndex, meetingCount: meetingCount,
                        meetingID: meta.meetingID, meetingFraction: fraction,
                        elapsedSeconds: elapsed, state: "Transcribing"
                    ))
                }
            } catch {
                return makeFailedResult(meta: meta, bundleID: bundleID, error: error)
            }
        } else {
            return makeFailedResult(
                meta: meta,
                bundleID: bundleID,
                error: RunnerJobError.speechUnavailable
            )
        }
    }

    private func makeFailedResult(
        meta: MeetingMeta,
        bundleID: UUID,
        error: any Error
    ) -> AppleMeetingResult {
        AppleMeetingResult(
            bundleID: bundleID,
            meetingID: meta.meetingID,
            status: .failed,
            requestedLocale: meta.appleLocale,
            config: AppleConfig(),
            audioDurationSeconds: meta.durationSeconds,
            error: ErrorInfo(error)
        )
    }

    private func isSpeechAvailable() -> Bool {
        if #available(macOS 26, *) {
            return AppleTranscription.isAvailable
        }
        return false
    }

    private func querySupportedLocales() async -> [String] {
        if #available(macOS 26, *) {
            return await AppleTranscription.supportedLocaleIdentifiers()
        }
        return []
    }

    private func queryInstalledLocales() async -> [String] {
        if #available(macOS 26, *) {
            return await AppleTranscription.installedLocaleIdentifiers()
        }
        return []
    }
}
