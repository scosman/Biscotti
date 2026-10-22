import Foundation

/// The result of running Apple SpeechTranscriber on one meeting.
/// Written by the runner app; read by the analyze command.
public struct AppleMeetingResult: Codable, Sendable, Equatable {
    public var schemaVersion: Int
    public var bundleID: UUID
    public var meetingID: String
    public var status: RunStatus
    public var requestedLocale: String
    public var resolvedLocale: String?
    public var config: AppleConfig
    public var assets: AssetEvent?
    public var timing: TimedRun?
    public var audioDurationSeconds: Double
    public var memory: MemoryReport?
    public var results: [AppleResult]
    public var error: ErrorInfo?

    public init(
        schemaVersion: Int = SchemaVersions.appleResult,
        bundleID: UUID,
        meetingID: String,
        status: RunStatus,
        requestedLocale: String,
        resolvedLocale: String? = nil,
        config: AppleConfig,
        assets: AssetEvent? = nil,
        timing: TimedRun? = nil,
        audioDurationSeconds: Double,
        memory: MemoryReport? = nil,
        results: [AppleResult] = [],
        error: ErrorInfo? = nil
    ) {
        self.schemaVersion = schemaVersion
        self.bundleID = bundleID
        self.meetingID = meetingID
        self.status = status
        self.requestedLocale = requestedLocale
        self.resolvedLocale = resolvedLocale
        self.config = config
        self.assets = assets
        self.timing = timing
        self.audioDurationSeconds = audioDurationSeconds
        self.memory = memory
        self.results = results
        self.error = error
    }
}

/// Configuration snapshot of the Apple SpeechTranscriber run.
public struct AppleConfig: Codable, Sendable, Equatable {
    public var module: String
    public var transcriptionOptions: [String]
    public var reportingOptions: [String]
    public var attributeOptions: [String]
    public var inputPath: String

    public init(
        module: String = "SpeechTranscriber",
        transcriptionOptions: [String] = [],
        reportingOptions: [String] = ["alternativeTranscriptions"],
        attributeOptions: [String] = ["audioTimeRange", "transcriptionConfidence"],
        inputPath: String = "analyzeSequence(from: AVAudioFile)"
    ) {
        self.module = module
        self.transcriptionOptions = transcriptionOptions
        self.reportingOptions = reportingOptions
        self.attributeOptions = attributeOptions
        self.inputPath = inputPath
    }
}

/// Record of whether Apple speech assets had to be downloaded.
public struct AssetEvent: Codable, Sendable, Equatable {
    public var installNeeded: Bool
    public var startedAt: Date?
    public var finishedAt: Date?
    public var progressTotalUnitCount: Int64?
    public var error: ErrorInfo?

    public init(
        installNeeded: Bool,
        startedAt: Date? = nil,
        finishedAt: Date? = nil,
        progressTotalUnitCount: Int64? = nil,
        error: ErrorInfo? = nil
    ) {
        self.installNeeded = installNeeded
        self.startedAt = startedAt
        self.finishedAt = finishedAt
        self.progressTotalUnitCount = progressTotalUnitCount
        self.error = error
    }
}

/// Lossless representation of a CMTime value (plain integers, no CoreMedia import).
public struct CMTimeValue: Codable, Sendable, Equatable {
    public var value: Int64
    public var timescale: Int32
    public var flags: UInt32
    public var epoch: Int64
    public var seconds: Double?

    public init(value: Int64, timescale: Int32, flags: UInt32, epoch: Int64, seconds: Double?) {
        self.value = value
        self.timescale = timescale
        self.flags = flags
        self.epoch = epoch
        self.seconds = seconds
    }
}

/// One SpeechTranscriber result (phrase-level).
public struct AppleResult: Codable, Sendable, Equatable {
    public var index: Int
    public var rangeStart: CMTimeValue
    public var rangeDuration: CMTimeValue
    public var resultsFinalizationTime: CMTimeValue
    public var isFinal: Bool
    public var text: String
    public var runs: [AppleRun]
    public var alternatives: [AppleAlternative]

    public init(
        index: Int,
        rangeStart: CMTimeValue,
        rangeDuration: CMTimeValue,
        resultsFinalizationTime: CMTimeValue,
        isFinal: Bool,
        text: String,
        runs: [AppleRun],
        alternatives: [AppleAlternative] = []
    ) {
        self.index = index
        self.rangeStart = rangeStart
        self.rangeDuration = rangeDuration
        self.resultsFinalizationTime = resultsFinalizationTime
        self.isFinal = isFinal
        self.text = text
        self.runs = runs
        self.alternatives = alternatives
    }
}

/// One attributed run within an AppleResult's text.
public struct AppleRun: Codable, Sendable, Equatable {
    public var text: String
    public var charOffset: Int
    public var charLength: Int
    public var timeStart: CMTimeValue?
    public var timeDuration: CMTimeValue?
    public var confidence: Double?
    public var attributesDebug: String

    public init(
        text: String,
        charOffset: Int,
        charLength: Int,
        timeStart: CMTimeValue? = nil,
        timeDuration: CMTimeValue? = nil,
        confidence: Double? = nil,
        attributesDebug: String = ""
    ) {
        self.text = text
        self.charOffset = charOffset
        self.charLength = charLength
        self.timeStart = timeStart
        self.timeDuration = timeDuration
        self.confidence = confidence
        self.attributesDebug = attributesDebug
    }
}

/// An alternative transcription for an AppleResult.
public struct AppleAlternative: Codable, Sendable, Equatable {
    public var text: String
    public var runs: [AppleRun]

    public init(text: String, runs: [AppleRun] = []) {
        self.text = text
        self.runs = runs
    }
}

/// A single runner session record appended to run.json.
public struct RunnerSession: Codable, Sendable, Equatable {
    public var sessionID: UUID
    public var bundleID: UUID
    public var appVersion: String
    public var machine: MachineInfo
    public var startedAt: Date
    public var endedAt: Date?
    public var speechTranscriberAvailable: Bool
    public var supportedLocales: [String]
    public var installedLocales: [String]
    public var force: Bool
    public var meetingsAttempted: [String]
    public var meetingsSkipped: [String]

    public init(
        sessionID: UUID = UUID(),
        bundleID: UUID,
        appVersion: String,
        machine: MachineInfo,
        startedAt: Date,
        endedAt: Date? = nil,
        speechTranscriberAvailable: Bool,
        supportedLocales: [String] = [],
        installedLocales: [String] = [],
        force: Bool = false,
        meetingsAttempted: [String] = [],
        meetingsSkipped: [String] = []
    ) {
        self.sessionID = sessionID
        self.bundleID = bundleID
        self.appVersion = appVersion
        self.machine = machine
        self.startedAt = startedAt
        self.endedAt = endedAt
        self.speechTranscriberAvailable = speechTranscriberAvailable
        self.supportedLocales = supportedLocales
        self.installedLocales = installedLocales
        self.force = force
        self.meetingsAttempted = meetingsAttempted
        self.meetingsSkipped = meetingsSkipped
    }
}

/// The top-level run.json file (array of runner sessions).
public struct RunFile: Codable, Sendable, Equatable {
    public var schemaVersion: Int
    public var sessions: [RunnerSession]

    public init(schemaVersion: Int = SchemaVersions.runFile, sessions: [RunnerSession] = []) {
        self.schemaVersion = schemaVersion
        self.sessions = sessions
    }
}
