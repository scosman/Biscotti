import Foundation
import SpeakerKit
import STTLabCore
import WhisperKit

// MARK: - Saved diarization types

/// A serializable snapshot of a SpeakerKit SpeakerSegment.
public struct SavedSpeakerSegment: Codable, Sendable, Equatable {
    public var speaker: SpeakerInfo
    public var startFrame: Int
    public var endFrame: Int
    public var startTime: Float
    public var endTime: Float

    public init(
        speaker: SpeakerInfo,
        startFrame: Int,
        endFrame: Int,
        startTime: Float,
        endTime: Float
    ) {
        self.speaker = speaker
        self.startFrame = startFrame
        self.endFrame = endFrame
        self.startTime = startTime
        self.endTime = endTime
    }

    public init(_ segment: SpeakerSegment) {
        speaker = segment.speaker
        startFrame = segment.startFrame
        endFrame = segment.endFrame
        startTime = segment.startTime
        endTime = segment.endTime
    }
}

/// A serializable snapshot of a SpeakerKit DiarizationResult.
public struct SavedDiarization: Codable, Sendable, Equatable {
    public var speakerCount: Int
    public var totalFrames: Int
    public var frameRate: Float
    public var segments: [SavedSpeakerSegment]

    public init(
        speakerCount: Int,
        totalFrames: Int,
        frameRate: Float,
        segments: [SavedSpeakerSegment]
    ) {
        self.speakerCount = speakerCount
        self.totalFrames = totalFrames
        self.frameRate = frameRate
        self.segments = segments
    }

    public init(_ result: DiarizationResult) {
        speakerCount = result.speakerCount
        totalFrames = result.totalFrames
        frameRate = result.frameRate
        segments = result.segments.map { SavedSpeakerSegment($0) }
    }

    /// Rebuild a DiarizationResult from the saved data using the public generic init.
    public func rebuild() -> DiarizationResult {
        let rebuilt = segments.map { seg in
            SpeakerSegment(
                speaker: seg.speaker,
                startFrame: seg.startFrame,
                endFrame: seg.endFrame,
                frameRate: frameRate
            )
        }
        return DiarizationResult(
            speakerCount: speakerCount,
            totalFrames: totalFrames,
            frameRate: frameRate,
            segments: rebuilt
        )
    }
}

/// Output saved per meeting for the SpeakerKit diarization run.
public struct DiarizationOutput: Codable, Sendable, Equatable {
    public var schemaVersion: Int
    public var meetingID: String
    public var status: RunStatus
    public var settings: [String: String]
    public var machine: MachineInfo
    public var timing: TimedRun?
    public var audioDurationSeconds: Double
    public var memory: MemoryReport?
    public var diarization: SavedDiarization?
    public var timingsDescription: String?
    public var error: ErrorInfo?

    public init(
        schemaVersion: Int = SchemaVersions.diarization,
        meetingID: String,
        status: RunStatus,
        settings: [String: String],
        machine: MachineInfo,
        timing: TimedRun? = nil,
        audioDurationSeconds: Double,
        memory: MemoryReport? = nil,
        diarization: SavedDiarization? = nil,
        timingsDescription: String? = nil,
        error: ErrorInfo? = nil
    ) {
        self.schemaVersion = schemaVersion
        self.meetingID = meetingID
        self.status = status
        self.settings = settings
        self.machine = machine
        self.timing = timing
        self.audioDurationSeconds = audioDurationSeconds
        self.memory = memory
        self.diarization = diarization
        self.timingsDescription = timingsDescription
        self.error = error
    }
}

// MARK: - Runner

/// Runs SpeakerKit diarization on each meeting's merged WAV, saving results to
/// `home/diarization/<mid>.json`. Loads SpeakerKit once and processes meetings in manifest order.
public enum DiarizationRunner {
    /// Run SpeakerKit diarization on each meeting in the bundle.
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
        let diarizationDir = workspace.appendingPathComponent("home/diarization")

        let machine = MachineInfo.current()
        let downloadBase = ProductionSettings.downloadBase()
        let settings: [String: String] = [
            "downloadBase": downloadBase.path,
            "argmaxVersion": ProductionSettings.argmaxVersion,
            "strategy": ProductionSettings.diarizationStrategy
        ]

        // Load SpeakerKit once.
        log.log("Loading SpeakerKit model")
        let config = PyannoteConfig(
            downloadBase: downloadBase.path,
            download: true,
            load: false,
            verbose: false
        )
        let speaker = try await SpeakerKit(config)
        log.log("SpeakerKit model loaded")

        var completed = 0
        var failed = 0
        var skipped = 0

        let meetingsToProcess = filterMeetings(
            bundle.manifest.meetings, filter: meetingFilter
        )

        for mid in meetingsToProcess {
            let outputURL = diarizationDir.appendingPathComponent("\(mid).json")

            // Skip if already completed (unless force).
            if !force, FileManager.default.fileExists(atPath: outputURL.path) {
                let existing: DiarizationOutput? = try? JSONFiles.read(from: outputURL)
                if existing?.status == .completed {
                    log.log("\(mid): diarization already completed (skip)")
                    skipped += 1
                    continue
                }
            }

            log.log("\(mid): running diarization...")

            do {
                let meta = bundle.metas.first { $0.meetingID == mid }!
                let wavURL = bundleDir
                    .appendingPathComponent("meetings/\(mid)/\(meta.audioFile)")
                let samples = try AudioProcessor.loadAudioAsFloatArray(fromPath: wavURL.path)
                let audioDuration = Double(samples.count) / meta.sampleRate

                let sampler = MemorySampler(interval: 0.5, watchSystemProcesses: false)
                await sampler.start()

                let start = Date()
                let result = try await speaker.diarize(audioArray: samples)
                let end = Date()
                let timing = TimedRun(start: start, end: end)

                let memory = await sampler.stop()

                let saved = SavedDiarization(result)
                let output = DiarizationOutput(
                    meetingID: mid,
                    status: .completed,
                    settings: settings,
                    machine: machine,
                    timing: timing,
                    audioDurationSeconds: audioDuration,
                    memory: memory,
                    diarization: saved,
                    timingsDescription: String(describing: result.timings)
                )
                try JSONFiles.write(output, to: outputURL)
                log.log("\(mid): done (\(String(format: "%.1f", timing.wallSeconds))s, "
                    + "\(saved.segments.count) segments, "
                    + "\(saved.speakerCount) speakers)")
                completed += 1

            } catch {
                let output = DiarizationOutput(
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
        }

        log.log("Diarization: \(completed) completed, \(failed) failed, \(skipped) skipped")
        return (completed, failed, skipped)
    }
}
