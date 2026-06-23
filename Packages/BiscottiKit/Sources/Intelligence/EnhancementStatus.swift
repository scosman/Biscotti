/// Per-meeting AI enhancement status, observed by the UI for status indicators.
public enum EnhancementStatus: Sendable, Equatable {
    /// Set synchronously at the start of an auto-enhancement or manual
    /// generate run, before any async work (settings reads, model load).
    /// Prevents the UI from flashing the "Generate Summary" button
    /// during the async gap between triggering and the first real stage.
    case preparing
    case identifyingSpeakers
    case summarizing
    case generatingTitle
    case completed
    case failed(message: String)
}

/// Model download lifecycle state, observed by Settings for the download row.
public enum ModelDownloadState: Sendable, Equatable {
    /// State not yet determined (e.g. before first disk check).
    case unknown
    case notDownloaded
    /// `fraction` is nil when the server doesn't provide Content-Length.
    case downloading(fraction: Double?)
    case downloaded
    case failed(message: String)
}

/// Settings that gate the AI auto-run. Read from DataStore on each run.
/// A single `enabled` flag maps to `AppSettings.aiAnalysisEnabled`.
public struct AISettings: Sendable {
    public var enabled: Bool

    public init(enabled: Bool) {
        self.enabled = enabled
    }
}
