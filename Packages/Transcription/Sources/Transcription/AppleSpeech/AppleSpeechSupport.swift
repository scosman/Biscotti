import Foundation

/// Whether Apple Speech is available on this machine.
public enum AppleSpeechAvailability: Sendable, Equatable {
    /// Apple Speech is available (macOS 26+ and SpeechTranscriber.isAvailable).
    case available
    /// macOS version is too old.
    case requiresOSUpdate(currentMajor: Int)
    /// macOS is 26+ but SpeechTranscriber.isAvailable returned false.
    case unavailable
}

/// App-side queries for Apple Speech availability and locale support.
///
/// Safe to call on macOS 15 (returns unavailable / empty). The real Speech
/// framework calls are behind `#if canImport(Speech)` + `@available(macOS 26, *)`.
/// Phase 2 adds the full implementation; this phase provides the availability check
/// and empty stubs so the UI layer can consume the API immediately.
public enum AppleSpeechSupport {
    /// Check whether Apple Speech is available on this OS version.
    public static func availability() -> AppleSpeechAvailability {
        let version = ProcessInfo.processInfo.operatingSystemVersion
        guard version.majorVersion >= 26 else {
            return .requiresOSUpdate(currentMajor: version.majorVersion)
        }
        // Phase 2 adds the real SpeechTranscriber.isAvailable check.
        // For now, report available on macOS 26+ (the spike will confirm).
        return .available
    }

    /// Supported locale identifiers. Empty when Apple Speech is unavailable.
    /// Phase 2 provides the real implementation via SpeechTranscriber.supportedLocales.
    public static func supportedLocales() async -> [String] {
        guard case .available = availability() else { return [] }
        // Phase 2 fills this in.
        return []
    }

    /// Find the supported locale equivalent to the given identifier.
    /// Returns nil when unsupported or unavailable.
    /// Phase 2 provides the real implementation.
    public static func supportedLocale(equivalentTo _: String) async -> String? {
        guard case .available = availability() else { return nil }
        // Phase 2 fills this in.
        return nil
    }

    /// Check whether assets are installed for a locale.
    /// Phase 2 provides the real implementation.
    public static func assetsInstalled(locale _: String) async throws -> Bool {
        guard case .available = availability() else { return false }
        // Phase 2 fills this in.
        return false
    }

    /// Install assets for a locale, reporting progress.
    /// Phase 2 provides the real implementation.
    public static func installAssets(
        locale _: String,
        progress _: @escaping @Sendable (Double?) -> Void
    ) async throws {
        guard case .available = availability() else {
            throw TranscriptionError.engineUnavailable(
                "Apple Speech requires macOS 26 or later"
            )
        }
        // Phase 2 fills this in.
    }
}
