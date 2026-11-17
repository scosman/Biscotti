import Foundation
import Transcription

// MARK: - Download state

/// Per-engine or per-component download state for the UI.
public enum EngineDownloadState: Sendable, Equatable {
    /// Not downloaded / not installed.
    case notDownloaded
    /// Download or install in progress. `fraction` is nil for indeterminate.
    case downloading(fraction: Double?)
    /// Installed / present on disk.
    case downloaded
    /// Download or install failed.
    case failed(message: String)
}

// MARK: - Locale option

/// A supported Apple Speech locale for display in the picker.
public struct AppleLocaleOption: Sendable, Equatable, Identifiable {
    /// Locale identifier (e.g. "en_US").
    public let id: String
    /// Full localized name (e.g. "English (United States)").
    public let displayName: String
    /// Language-only name (e.g. "English").
    public let languageName: String

    public init(id: String, displayName: String, languageName: String) {
        self.id = id
        self.displayName = displayName
        self.languageName = languageName
    }
}

// MARK: - Apple Speech provider protocol

/// App-side Apple Speech queries. Live impl wraps `Transcription.AppleSpeechSupport`.
/// Protocol seam allows fakes in tests.
public protocol AppleSpeechProviding: Sendable {
    /// Current availability.
    func availability() -> AppleSpeechAvailability
    /// Runtime-supported locale identifiers.
    func supportedLocales() async -> [String]
    /// Supported locale equivalent to the given identifier, or nil.
    func supportedLocale(equivalentTo id: String) async -> String?
    /// Whether assets are installed for the locale. Errors map to false.
    func assetsInstalled(locale: String) async -> Bool
    /// Install assets for a locale, reporting determinate progress.
    func installAssets(
        locale: String,
        progress: @escaping @Sendable (Double?) -> Void
    ) async throws
}

// MARK: - Live implementation

/// Production `AppleSpeechProviding` that delegates to `AppleSpeechSupport`.
public struct LiveAppleSpeechProvider: AppleSpeechProviding {
    public init() {}

    public func availability() -> AppleSpeechAvailability {
        AppleSpeechSupport.availability()
    }

    public func supportedLocales() async -> [String] {
        await AppleSpeechSupport.supportedLocales()
    }

    public func supportedLocale(equivalentTo id: String) async -> String? {
        await AppleSpeechSupport.supportedLocale(equivalentTo: id)
    }

    public func assetsInstalled(locale: String) async -> Bool {
        await (try? AppleSpeechSupport.assetsInstalled(locale: locale)) ?? false
    }

    public func installAssets(
        locale: String,
        progress: @escaping @Sendable (Double?) -> Void
    ) async throws {
        try await AppleSpeechSupport.installAssets(locale: locale, progress: progress)
    }
}
