import Foundation
import SwiftData

// MARK: - AppSettings

/// Singleton-ish application settings stored in SwiftData.
@Model public final class AppSettings {
    /// JSON-encoded backing store for `customVocabulary`. SwiftData cannot materialize
    /// generic `Array<String>` from on-disk stores in SPM modules; `Data` works reliably.
    private var customVocabularyData = Data()

    /// User-defined vocabulary terms for transcription biasing.
    @Transient public var customVocabulary: [String] {
        get { (try? JSONDecoder().decode([String].self, from: customVocabularyData)) ?? [] }
        set { customVocabularyData = (try? JSONEncoder().encode(newValue)) ?? Data() }
    }

    public var launchAtLogin: Bool = false

    /// When true, closing the last window or pressing Cmd+Q terminates the app.
    /// When false (the default), those actions just hide the window and the app
    /// stays alive in the menu bar.
    public var exitOnWindowClose: Bool = false

    /// Whether the global ⌘⇧R hotkey is active. When true, pressing
    /// ⌘⇧R anywhere in the OS starts a Biscotti recording.
    public var globalRecordShortcutEnabled: Bool = true

    /// Lead time (in seconds) before a meeting start at which the menu bar
    /// shows the detailed "next meeting" text. `0` means never show.
    /// Default: 3600 (1 hour before).
    public var menuBarLeadTimeSeconds: Int = 3600

    /// Whether meeting-detected notifications are presented.
    public var monitorForMeetings: Bool = true

    /// Whether recording auto-stops when all mic users leave.
    public var stopRecordingAutomatically: Bool = true

    /// Raw string backing for `CalendarNotificationMode`. Stored as a
    /// String for SwiftData safety (same pattern as other enum-backed fields).
    public var calendarNotificationModeRaw: String = "allMeetings"

    /// Whether the user has completed the onboarding wizard.
    public var onboardingComplete: Bool = false

    /// JSON-encoded backing store for `enabledCalendarIDs`. Uses the same
    /// Data-backed pattern as `customVocabularyData` to avoid SwiftData's
    /// `[String]` materialization issues in SPM modules.
    private var enabledCalendarIDsData = Data()

    /// The set of calendar identifiers the user has enabled. `nil` means all
    /// calendars are enabled (the default).
    @Transient public var enabledCalendarIDs: Set<String>? {
        get {
            guard !enabledCalendarIDsData.isEmpty else { return nil }
            guard let array = try? JSONDecoder().decode([String].self, from: enabledCalendarIDsData) else {
                return nil
            }
            return Set(array)
        }
        set {
            if let newValue {
                enabledCalendarIDsData = (try? JSONEncoder().encode(Array(newValue).sorted())) ?? Data()
            } else {
                enabledCalendarIDsData = Data()
            }
        }
    }

    public init(
        customVocabulary: [String] = [],
        launchAtLogin: Bool = false,
        exitOnWindowClose: Bool = false,
        globalRecordShortcutEnabled: Bool = true,
        menuBarLeadTimeSeconds: Int = 3600,
        monitorForMeetings: Bool = true,
        stopRecordingAutomatically: Bool = true,
        calendarNotificationModeRaw: String = "allMeetings",
        onboardingComplete: Bool = false,
        enabledCalendarIDs: Set<String>? = nil
    ) {
        customVocabularyData = (try? JSONEncoder().encode(customVocabulary)) ?? Data()
        self.launchAtLogin = launchAtLogin
        self.exitOnWindowClose = exitOnWindowClose
        self.globalRecordShortcutEnabled = globalRecordShortcutEnabled
        self.menuBarLeadTimeSeconds = menuBarLeadTimeSeconds
        self.monitorForMeetings = monitorForMeetings
        self.stopRecordingAutomatically = stopRecordingAutomatically
        self.calendarNotificationModeRaw = calendarNotificationModeRaw
        self.onboardingComplete = onboardingComplete
        if let enabledCalendarIDs {
            enabledCalendarIDsData = (try? JSONEncoder().encode(Array(enabledCalendarIDs).sorted())) ?? Data()
        }
    }
}
