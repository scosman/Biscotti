import Foundation
import STTLabCore

/// Per-meeting metrics collected during analysis.
public struct MeetingMetrics: Codable, Sendable {
    public var meetingID: String
    public var durationSeconds: Double
    public var speakerCount: Int
    public var locale: String

    // Engine availability.
    public var appleStatus: String   // "completed", "failed", "not run", "unsupported locale"
    public var whisperStatus: String
    public var referenceStatus: String

    // WER.
    public var werAppleVsRef: WERResult?
    public var werWhisperVsRef: WERResult?
    public var werAppleVsWhisper: WERResult?

    // Tie-break.
    public var tieBreakCounts: TieBreakCounts?
    public var tieBreakRegions: [DisagreementRegion]?

    // Flags.
    public var flags: [String]

    // Text quality.
    public var textQualityApple: TextQualityResult?
    public var textQualityWhisper: TextQualityResult?
    public var textQualityReference: TextQualityResult?

    // Timing.
    public var timingAppleVsWhisper: TimingResult?
    public var timingAppleVsRef: TimingResult?
    public var timingWhisperVsRef: TimingResult?

    // Apple run stats.
    public var appleRunStats: RunStats?

    // Speaker metrics.
    public var speakerAgreementAW: SpeakerAgreement?
    public var speakerAgreementAR: SpeakerAgreement?
    public var speakerAgreementWR: SpeakerAgreement?
    public var segmentStatsApple: SegmentStats?
    public var segmentStatsWhisper: SegmentStats?
    public var segmentStatsReference: SegmentStats?
    public var speakerDisagreementSample: [SpeakerDisagreementRun]?

    // Speed.
    public var appleWallSeconds: Double?
    public var whisperWallSeconds: Double?
    public var referenceWallSeconds: Double?
    public var appleRTF: Double?
    public var whisperRTF: Double?

    // Memory.
    public var appleMemory: MemoryReport?
    public var whisperMemory: MemoryReport?
    public var diarizationMemory: MemoryReport?

    // Dropped untimed words per engine during speaker alignment.
    public var droppedUntimedApple: Int?
    public var droppedUntimedWhisper: Int?
    public var droppedUntimedReference: Int?

    public init(meetingID: String, durationSeconds: Double = 0, speakerCount: Int = 0,
                locale: String = "en_US", appleStatus: String = "not run",
                whisperStatus: String = "not run", referenceStatus: String = "not run",
                flags: [String] = []) {
        self.meetingID = meetingID
        self.durationSeconds = durationSeconds
        self.speakerCount = speakerCount
        self.locale = locale
        self.appleStatus = appleStatus
        self.whisperStatus = whisperStatus
        self.referenceStatus = referenceStatus
        self.flags = flags
    }
}

/// Machine info for report display.
public struct ReportMachine: Codable, Sendable {
    public var name: String       // "home" or "runner"
    public var chip: String
    public var memoryGB: Int
    public var osVersion: String

    public init(name: String, chip: String, memoryGB: Int, osVersion: String) {
        self.name = name
        self.chip = chip
        self.memoryGB = memoryGB
        self.osVersion = osVersion
    }
}

/// Top-level report model: aggregate of per-meeting and overall metrics.
public struct ReportModel: Codable, Sendable {
    // Run info.
    public var bundleID: String
    public var homeMachine: ReportMachine?
    public var runnerMachine: ReportMachine?
    public var referenceModel: String?
    public var referenceZDR: Bool?
    public var referenceTotalCost: Double?

    // Per-meeting.
    public var meetings: [MeetingMetrics]

    // Pooled WER.
    public var pooledWerAppleVsRef: WERResult?
    public var pooledWerWhisperVsRef: WERResult?
    public var pooledWerAppleVsWhisper: WERResult?

    // Aggregated tie-break.
    public var overallTieBreakCounts: TieBreakCounts?
    public var tieBreakSample: [DisagreementRegion]?

    // Speed summaries.
    public var medianAppleRTF: Double?
    public var medianWhisperRTF: Double?

    // Timing summaries.
    public var overallTimingAW: TimingResult?
    public var overallTimingAR: TimingResult?
    public var overallTimingWR: TimingResult?

    // Speaker summaries.
    public var overallSpeakerAgreementAW: SpeakerAgreement?
    public var overallSpeakerAgreementAR: SpeakerAgreement?
    public var overallSpeakerAgreementWR: SpeakerAgreement?

    // Text quality summaries (pooled is not meaningful; per-meeting in the table).

    // Caveats.
    public var caveats: [String]

    // Errors.
    public var errors: [String]

    public init(bundleID: String = "", meetings: [MeetingMetrics] = [],
                caveats: [String] = [], errors: [String] = []) {
        self.bundleID = bundleID
        self.meetings = meetings
        self.caveats = caveats
        self.errors = errors
    }
}
