import Foundation
import STTLabCore
import WhisperKit

/// Output saved per meeting for the WhisperKit engine run.
public struct WhisperOutput: Codable, Sendable {
    public var schemaVersion: Int
    public var meetingID: String
    public var status: RunStatus
    public var settings: [String: String]
    public var machine: MachineInfo
    public var modelLoadSeconds: Double?
    public var timing: TimedRun?
    public var audioDurationSeconds: Double
    public var memory: MemoryReport?
    public var results: [TranscriptionResult]?
    public var error: ErrorInfo?

    public init(
        schemaVersion: Int = SchemaVersions.whisper,
        meetingID: String,
        status: RunStatus,
        settings: [String: String],
        machine: MachineInfo,
        modelLoadSeconds: Double? = nil,
        timing: TimedRun? = nil,
        audioDurationSeconds: Double,
        memory: MemoryReport? = nil,
        results: [TranscriptionResult]? = nil,
        error: ErrorInfo? = nil
    ) {
        self.schemaVersion = schemaVersion
        self.meetingID = meetingID
        self.status = status
        self.settings = settings
        self.machine = machine
        self.modelLoadSeconds = modelLoadSeconds
        self.timing = timing
        self.audioDurationSeconds = audioDurationSeconds
        self.memory = memory
        self.results = results
        self.error = error
    }
}

/// Runs WhisperKit transcription on each meeting's merged WAV, saving results to
/// `home/whisper/<mid>.json`. Loads the model once and processes meetings in manifest order.
public enum WhisperRunner {
    /// Run WhisperKit on each meeting in the bundle.
    ///
    /// - Parameters:
    ///   - workspace: The workspace directory URL.
    ///   - meetingFilter: If non-empty, only process these meeting IDs.
    ///   - force: Re-run meetings that already have a completed output.
    ///   - log: Logger for status output.
    /// - Returns: Count of (completed, failed, skipped) meetings.
    @discardableResult
    public static func run(
        workspace: URL,
        meetingFilter: [String] = [],
        force: Bool = false,
        log: RunLog
    ) async throws -> (completed: Int, failed: Int, skipped: Int) {
        _ = try ConsentGate.require(workspace: workspace)
        let bundleDir = workspace.appendingPathComponent("bundle")
        let bundle = try BundleLoader.load(from: bundleDir)
        let whisperDir = workspace.appendingPathComponent("home/whisper")

        let machine = MachineInfo.current()
        let settings: [String: String] = [
            "model": ProductionSettings.sttModel,
            "repo": ProductionSettings.sttModelRepo,
            "wordTimestamps": String(ProductionSettings.enableWordTimestamps),
            "argmaxVersion": ProductionSettings.argmaxVersion
        ]

        // Load model once.
        log.log("Loading WhisperKit model: \(ProductionSettings.sttModel)")
        let loadStart = Date()
        let whisper = try await WhisperKit(
            model: ProductionSettings.sttModel,
            downloadBase: ProductionSettings.downloadBase(),
            modelRepo: ProductionSettings.sttModelRepo,
            verbose: false,
            load: true,
            download: true
        )
        let loadSeconds = Date().timeIntervalSince(loadStart)
        log.log("Model loaded in \(String(format: "%.1f", loadSeconds))s")

        let decodingOptions = DecodingOptions(wordTimestamps: ProductionSettings.enableWordTimestamps)

        var completed = 0
        var failed = 0
        var skipped = 0
        var isFirstMeeting = true

        let meetingsToProcess = filterMeetings(
            bundle.manifest.meetings, filter: meetingFilter
        )

        for mid in meetingsToProcess {
            let outputURL = whisperDir.appendingPathComponent("\(mid).json")

            // Skip if already completed (unless force).
            if !force, FileManager.default.fileExists(atPath: outputURL.path) {
                let existing: WhisperOutput? = try? JSONFiles.read(from: outputURL)
                if existing?.status == .completed {
                    log.log("\(mid): whisper already completed (skip)")
                    skipped += 1
                    continue
                }
            }

            log.log("\(mid): running whisper...")

            do {
                let meta = bundle.metas.first { $0.meetingID == mid }!
                let wavURL = bundleDir
                    .appendingPathComponent("meetings/\(mid)/\(meta.audioFile)")
                let samples = try AudioProcessor.loadAudioAsFloatArray(fromPath: wavURL.path)
                let audioDuration = Double(samples.count) / meta.sampleRate

                let sampler = MemorySampler(interval: 0.5, watchSystemProcesses: false)
                await sampler.start()

                let start = Date()
                let results = try await whisper.transcribe(
                    audioArray: samples,
                    decodeOptions: decodingOptions
                )
                let end = Date()
                let timing = TimedRun(start: start, end: end)

                let memory = await sampler.stop()

                let output = WhisperOutput(
                    meetingID: mid,
                    status: .completed,
                    settings: settings,
                    machine: machine,
                    modelLoadSeconds: isFirstMeeting ? loadSeconds : nil,
                    timing: timing,
                    audioDurationSeconds: audioDuration,
                    memory: memory,
                    results: results
                )
                try JSONFiles.write(output, to: outputURL)
                log.log("\(mid): done (\(String(format: "%.1f", timing.wallSeconds))s, "
                    + "RTF \(String(format: "%.2f", audioDuration / timing.wallSeconds)))")
                completed += 1

            } catch {
                let output = WhisperOutput(
                    meetingID: mid,
                    status: .failed,
                    settings: settings,
                    machine: machine,
                    audioDurationSeconds: 0,
                    error: ErrorInfo(error)
                )
                try? JSONFiles.write(output, to: outputURL)
                log.log("\(mid): FAILED — \(error)")
                failed += 1
            }

            isFirstMeeting = false
        }

        log.log("Whisper: \(completed) completed, \(failed) failed, \(skipped) skipped")
        return (completed, failed, skipped)
    }
}

/// Filter meeting IDs by an optional user-provided list.
func filterMeetings(
    _ allMIDs: [String],
    filter: [String]
) -> [String] {
    if filter.isEmpty { return allMIDs }
    return allMIDs.filter { filter.contains($0) }
}
