import Foundation
import Observation

/// Recording-automation settings. Stored in `UserDefaults` as JSON
/// rather than in the SwiftData schema, so the fork needs no schema
/// migration and stays easy to rebase onto upstream releases.
public struct AutomationSettings: Codable, Sendable, Equatable {
    public var recordingMode: RecordingMode
    /// In `.automatic` mode, also auto-record meetings detected in a
    /// browser. Off by default: browser mic use is often not a meeting.
    public var autoRecordInBrowsers: Bool
    /// Stop the current recording when the screen locks.
    public var stopOnScreenLock: Bool
    /// Record the meeting app's window data (participant names, highlight
    /// and bold states) alongside every recording, for speaker detection.
    public var captureMeetingUI: Bool
    public var retention: RetentionPolicy
    public var exportTargets: [ExportTarget]
    /// Microphone priority, top first. Empty means "same as system".
    /// The system default is always the implicit last choice.
    public var micPriority: [MicPriorityEntry]
    /// During a recording, move to a higher-priority mic when it connects.
    public var micSwitchUp: Bool
    /// After transcription, label the user's lines from the mic track and
    /// name remote voices from the meeting-window capture.
    public var nameSpeakers: Bool
    /// The user's name in transcripts. Empty means the Mac account's name.
    public var transcriptName: String
    /// Meeting apps (bundle IDs) the window capture leaves alone.
    public var captureExcludedApps: [String]
    /// Delete meeting-window capture files after this many days (0 = keep).
    public var captureKeepDays: Int
    /// What re-transcribing a meeting does to its automatic export.
    public var reTranscribeExport: ReTranscribeExportBehavior
    /// Post a quiet notification saying what each export did.
    public var notifyOnExport: Bool
    /// Offer to turn on live captions when a call window has them off.
    public var offerCaptions: Bool = true

    public init(
        recordingMode: RecordingMode = .ask,
        autoRecordInBrowsers: Bool = false,
        stopOnScreenLock: Bool = true,
        captureMeetingUI: Bool = true,
        retention: RetentionPolicy = RetentionPolicy(),
        exportTargets: [ExportTarget] = [],
        micPriority: [MicPriorityEntry] = [],
        micSwitchUp: Bool = true,
        nameSpeakers: Bool = true,
        transcriptName: String = "",
        captureExcludedApps: [String] = [],
        captureKeepDays: Int = 30,
        reTranscribeExport: ReTranscribeExportBehavior = .ask,
        notifyOnExport: Bool = true
    ) {
        self.recordingMode = recordingMode
        self.autoRecordInBrowsers = autoRecordInBrowsers
        self.stopOnScreenLock = stopOnScreenLock
        self.captureMeetingUI = captureMeetingUI
        self.retention = retention
        self.exportTargets = exportTargets
        self.micPriority = micPriority
        self.micSwitchUp = micSwitchUp
        self.nameSpeakers = nameSpeakers
        self.transcriptName = transcriptName
        self.captureExcludedApps = captureExcludedApps
        self.captureKeepDays = captureKeepDays
        self.reTranscribeExport = reTranscribeExport
        self.notifyOnExport = notifyOnExport
    }

    public var enabledExportTargets: [ExportTarget] {
        exportTargets.filter(\.isEnabled)
    }

    private enum CodingKeys: String, CodingKey {
        case recordingMode, autoRecordInBrowsers, stopOnScreenLock, captureMeetingUI, retention, exportTargets
        case micPriority, micSwitchUp, nameSpeakers, transcriptName, captureExcludedApps, captureKeepDays, reTranscribeExport, notifyOnExport
        case offerCaptions
    }

    /// Tolerant decoding: a missing or unreadable key falls back to its
    /// default instead of discarding every saved setting.
    public init(from decoder: any Decoder) throws {
        let defaults = AutomationSettings()
        let container = try decoder.container(keyedBy: CodingKeys.self)
        recordingMode = (try? container.decodeIfPresent(RecordingMode.self, forKey: .recordingMode))
            ?? defaults.recordingMode
        autoRecordInBrowsers = (try? container.decodeIfPresent(Bool.self, forKey: .autoRecordInBrowsers))
            ?? defaults.autoRecordInBrowsers
        stopOnScreenLock = (try? container.decodeIfPresent(Bool.self, forKey: .stopOnScreenLock))
            ?? defaults.stopOnScreenLock
        captureMeetingUI = (try? container.decodeIfPresent(Bool.self, forKey: .captureMeetingUI))
            ?? defaults.captureMeetingUI
        retention = (try? container.decodeIfPresent(RetentionPolicy.self, forKey: .retention))
            ?? defaults.retention
        exportTargets = (try? container.decodeIfPresent([ExportTarget].self, forKey: .exportTargets))
            ?? defaults.exportTargets
        micPriority = (try? container.decodeIfPresent([MicPriorityEntry].self, forKey: .micPriority))
            ?? defaults.micPriority
        micSwitchUp = (try? container.decodeIfPresent(Bool.self, forKey: .micSwitchUp))
            ?? defaults.micSwitchUp
        nameSpeakers = (try? container.decodeIfPresent(Bool.self, forKey: .nameSpeakers))
            ?? defaults.nameSpeakers
        transcriptName = (try? container.decodeIfPresent(String.self, forKey: .transcriptName))
            ?? defaults.transcriptName
        captureExcludedApps = (try? container.decodeIfPresent([String].self, forKey: .captureExcludedApps))
            ?? defaults.captureExcludedApps
        captureKeepDays = (try? container.decodeIfPresent(Int.self, forKey: .captureKeepDays))
            ?? defaults.captureKeepDays
        reTranscribeExport = (try? container.decodeIfPresent(ReTranscribeExportBehavior.self, forKey: .reTranscribeExport))
            ?? defaults.reTranscribeExport
        notifyOnExport = (try? container.decodeIfPresent(Bool.self, forKey: .notifyOnExport))
            ?? defaults.notifyOnExport
        offerCaptions = (try? container.decodeIfPresent(Bool.self, forKey: .offerCaptions))
            ?? defaults.offerCaptions
    }
}

/// Result of the most recent automatic export, shown in Settings.
public struct ExportStatus: Sendable, Equatable {
    public let date: Date
    public let meetingTitle: String
    /// Empty when every target succeeded.
    public let failures: [String]
    /// What happened, e.g. "Replaced the existing file in
    /// Transcriptions." Empty for older call sites.
    public let detail: String

    public init(date: Date, meetingTitle: String, failures: [String], detail: String = "") {
        self.date = date
        self.meetingTitle = meetingTitle
        self.failures = failures
        self.detail = detail
    }

    /// One line for the menu bar.
    public var menuLine: String {
        let time = date.formatted(date: .omitted, time: .shortened)
        if !failures.isEmpty {
            return "Export failed for \u{201C}\(meetingTitle)\u{201D} at \(time)"
        }
        return "Exported \u{201C}\(meetingTitle)\u{201D} at \(time)" + (detail.isEmpty ? "" : " \u{00B7} \(detail)")
    }
}

/// Observable owner of `AutomationSettings` plus the export ledger (which
/// meetings have been exported to every enabled target).
@MainActor @Observable
public final class AutomationSettingsStore {
    /// One line about the last speaker-naming pass, for the
    /// menu bar ("Nora Hale, Jamie Ford named"), with its meeting title.
    public var lastNamingReport: String?
    /// Re-transcriptions waiting to finish, with the export choice the user
    /// made when starting them. Read once when the meeting finishes.
    public var pendingReExport: [UUID: ReExportChoice] = [:]
    /// Permissions found missing at launch (`AppPermission` raw values).
    /// Non-empty shows the launch permission prompt until dismissed.
    public var missingPermissions: [String] = []

    public private(set) var settings: AutomationSettings
    /// Set by `AppCore` after each automatic export.
    public var lastExportStatus: ExportStatus?
    /// Set by `AppCore` after each grooming pass that deleted something.
    public var lastRetentionSummary: String?

    /// Live copy of the microphone policy for the audio engine's queue.
    @ObservationIgnored public let micPolicy = MicPolicyBox()

    @ObservationIgnored private let defaults: UserDefaults
    /// Meeting ID -> IDs of the targets it has been exported to.
    @ObservationIgnored private var exportLedger: [String: [String]]

    static let settingsKey = "biscotti.automation.settings.v1"
    /// The old ledger: meeting ID -> export time, for "every target at the time".
    static let legacyLedgerKey = "biscotti.automation.exportLedger.v1"
    static let ledgerKey = "biscotti.automation.exportLedger.v2"

    public init(defaults: UserDefaults) {
        self.defaults = defaults
        let loaded = Self.loadSettings(from: defaults)
        settings = loaded
        exportLedger = Self.loadLedger(from: defaults, targets: loaded.enabledExportTargets.map(\.id))
        micPolicy.update(priority: loaded.micPriority, allowSwitchUp: loaded.micSwitchUp)
    }

    /// The store the app uses.
    public static func live() -> AutomationSettingsStore {
        let store = AutomationSettingsStore(defaults: .standard)
        store.isLive = true
        return store
    }

    /// True for the app's real store. Launch-time checks that would pop up
    /// Settings or system prompts run only then, never in tests or previews.
    public private(set) var isLive = false

    /// A throwaway store backed by a unique defaults suite, with default
    /// settings except meeting UI capture, which is off. Used by previews and tests so they never read or write the
    /// user's real settings.
    public static func ephemeral() -> AutomationSettingsStore {
        let suite = "biscotti.automation.ephemeral.\(UUID().uuidString)"
        let store = AutomationSettingsStore(defaults: UserDefaults(suiteName: suite) ?? .standard)
        // Tests and previews must never capture whatever meeting app happens
        // to be open on the developer's Mac.
        store.update {
            $0.captureMeetingUI = false
            // Speaker naming reads real capture files; keep tests hermetic.
            $0.nameSpeakers = false
        }
        return store
    }

    /// Mutates and persists the settings.
    public func update(_ mutate: (inout AutomationSettings) -> Void) {
        var copy = settings
        mutate(&copy)
        guard copy != settings else { return }
        settings = copy
        micPolicy.update(priority: copy.micPriority, allowSwitchUp: copy.micSwitchUp)
        if let data = try? JSONEncoder().encode(copy) {
            defaults.set(data, forKey: Self.settingsKey)
        }
    }

    // MARK: - Export ledger

    /// True when the meeting has reached every export target enabled now. A
    /// target added later has not received older meetings, so they don't
    /// count as exported until it has.
    public func isExported(_ meetingID: UUID) -> Bool {
        let targets = settings.enabledExportTargets
        guard !targets.isEmpty, let done = exportLedger[meetingID.uuidString] else { return false }
        return targets.allSatisfy { done.contains($0.id.uuidString) }
    }

    /// Records that the meeting reached these targets.
    public func markExported(_ meetingID: UUID, targets: [UUID]) {
        guard !targets.isEmpty else { return }
        var done = Set(exportLedger[meetingID.uuidString] ?? [])
        done.formUnion(targets.map(\.uuidString))
        exportLedger[meetingID.uuidString] = done.sorted()
        defaults.set(exportLedger, forKey: Self.ledgerKey)
    }

    /// Records that the meeting reached every target enabled now.
    public func markExported(_ meetingID: UUID) {
        markExported(meetingID, targets: settings.enabledExportTargets.map(\.id))
    }

    /// Clears ledger entries, e.g. after targets change or meetings are deleted.
    public func forgetExports(_ meetingIDs: [UUID]) {
        guard !meetingIDs.isEmpty else { return }
        for id in meetingIDs {
            exportLedger.removeValue(forKey: id.uuidString)
        }
        defaults.set(exportLedger, forKey: Self.ledgerKey)
    }

    public func forgetAllExports() {
        exportLedger = [:]
        defaults.removeObject(forKey: Self.ledgerKey)
    }

    /// Reads the per-target ledger, or converts the old one: a meeting it
    /// listed had reached every target enabled at the time, which is the
    /// best record there is of where it went.
    private static func loadLedger(from defaults: UserDefaults, targets: [UUID]) -> [String: [String]] {
        if let ledger = defaults.dictionary(forKey: ledgerKey) as? [String: [String]] {
            return ledger
        }
        guard let legacy = defaults.dictionary(forKey: legacyLedgerKey) as? [String: Double] else { return [:] }
        let ids = targets.map(\.uuidString).sorted()
        let ledger = ids.isEmpty ? [:] : legacy.mapValues { _ in ids }
        defaults.set(ledger, forKey: ledgerKey)
        defaults.removeObject(forKey: legacyLedgerKey)
        return ledger
    }

    private static func loadSettings(from defaults: UserDefaults) -> AutomationSettings {
        guard let data = defaults.data(forKey: settingsKey),
              let decoded = try? JSONDecoder().decode(AutomationSettings.self, from: data)
        else { return AutomationSettings() }
        return decoded
    }
}
