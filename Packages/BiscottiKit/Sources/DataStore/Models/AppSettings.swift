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
        onboardingComplete: Bool = false,
        enabledCalendarIDs: Set<String>? = nil
    ) {
        customVocabularyData = (try? JSONEncoder().encode(customVocabulary)) ?? Data()
        self.launchAtLogin = launchAtLogin
        self.exitOnWindowClose = exitOnWindowClose
        self.onboardingComplete = onboardingComplete
        if let enabledCalendarIDs {
            enabledCalendarIDsData = (try? JSONEncoder().encode(Array(enabledCalendarIDs).sorted())) ?? Data()
        }
    }
}
