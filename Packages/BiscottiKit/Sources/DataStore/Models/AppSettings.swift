import Foundation
import SwiftData

// MARK: - AppSettings

/// Singleton-ish application settings stored in SwiftData.
@Model public final class AppSettings: @unchecked Sendable {
    /// JSON-encoded backing store for `customVocabulary`. SwiftData cannot materialize
    /// generic `Array<String>` from on-disk stores in SPM modules; `Data` works reliably.
    private var customVocabularyData = Data()

    /// User-defined vocabulary terms for transcription biasing.
    @Transient public var customVocabulary: [String] {
        get { (try? JSONDecoder().decode([String].self, from: customVocabularyData)) ?? [] }
        set { customVocabularyData = (try? JSONEncoder().encode(newValue)) ?? Data() }
    }

    public var launchAtLogin: Bool

    public init(
        customVocabulary: [String] = [],
        launchAtLogin: Bool = false
    ) {
        customVocabularyData = (try? JSONEncoder().encode(customVocabulary)) ?? Data()
        self.launchAtLogin = launchAtLogin
    }
}
