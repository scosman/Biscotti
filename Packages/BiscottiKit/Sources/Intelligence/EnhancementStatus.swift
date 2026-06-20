/// Per-meeting AI enhancement status, observed by the UI for status indicators.
public enum EnhancementStatus: Sendable, Equatable {
    case identifyingSpeakers
    case summarizing
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
public struct AISettings: Sendable {
    public var summarize: Bool
    public var guessSpeakers: Bool

    public init(summarize: Bool, guessSpeakers: Bool) {
        self.summarize = summarize
        self.guessSpeakers = guessSpeakers
    }
}
