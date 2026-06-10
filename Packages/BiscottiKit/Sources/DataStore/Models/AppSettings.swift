import Foundation
import SwiftData

// MARK: - AppSettings

/// Singleton-ish application settings stored in SwiftData.
@Model public final class AppSettings: @unchecked Sendable {
    public var customVocabulary: [String] = []
    public var launchAtLogin: Bool = false

    public init(
        customVocabulary: [String] = [],
        launchAtLogin: Bool = false
    ) {
        self.customVocabulary = customVocabulary
        self.launchAtLogin = launchAtLogin
    }
}
