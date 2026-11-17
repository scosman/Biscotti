import DataStore

// MARK: - Detection

/// How to discover whether a destination app is installed.
public enum DestinationDetection: Equatable, Sendable {
    /// Look up via `NSWorkspace.urlForApplication(toOpen:)` with the given scheme URL.
    case urlScheme(String)
    /// Look up via `NSWorkspace.urlForApplication(withBundleIdentifier:)`.
    case bundleID(String)
}

// MARK: - Display info

public extension ExportDestination {
    /// Human-readable name shown in UI and alerts.
    var displayName: String {
        switch self {
        case .obsidian: "Obsidian"
        case .bear: "Bear"
        case .appleNotes: "Apple Notes"
        }
    }

    /// How to detect whether the app is installed.
    var detection: DestinationDetection {
        switch self {
        case .obsidian: .urlScheme("obsidian")
        case .bear: .urlScheme("bear")
        case .appleNotes: .bundleID("com.apple.Notes")
        }
    }
}
