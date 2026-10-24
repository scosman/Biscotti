import Foundation
import os.log

#if canImport(Speech)
    import Speech
#endif

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
public enum AppleSpeechSupport {
    private static let log = Logger(
        subsystem: "net.scosman.biscotti",
        category: "AppleSpeech"
    )

    /// Check whether Apple Speech is available on this OS version.
    public static func availability() -> AppleSpeechAvailability {
        let version = ProcessInfo.processInfo.operatingSystemVersion
        guard version.majorVersion >= 26 else {
            return .requiresOSUpdate(currentMajor: version.majorVersion)
        }
        #if canImport(Speech)
            if #available(macOS 26, *) {
                return SpeechTranscriber.isAvailable ? .available : .unavailable
            }
        #endif
        return .unavailable
    }

    /// Supported locale identifiers. Empty when Apple Speech is unavailable.
    public static func supportedLocales() async -> [String] {
        guard case .available = availability() else { return [] }
        #if canImport(Speech)
            if #available(macOS 26, *) {
                return await SpeechTranscriber.supportedLocales.map(\.identifier)
            }
        #endif
        return []
    }

    /// Find the supported locale equivalent to the given identifier.
    /// Returns nil when unsupported or unavailable.
    public static func supportedLocale(equivalentTo identifier: String) async -> String? {
        guard case .available = availability() else { return nil }
        #if canImport(Speech)
            if #available(macOS 26, *) {
                let locale = Locale(identifier: identifier)
                guard let resolved = await SpeechTranscriber.supportedLocale(
                    equivalentTo: locale
                ) else {
                    return nil
                }
                return resolved.identifier
            }
        #endif
        return nil
    }

    /// Check whether assets are installed for a locale.
    ///
    /// Side effect: reserves the locale for this process (A6 releases others first).
    /// Returns true when `assetInstallationRequest(supporting:)` returns nil
    /// (research recommendation: status(forModules:) is unreliable).
    public static func assetsInstalled(locale: String) async throws -> Bool {
        guard case .available = availability() else { return false }
        #if canImport(Speech)
            if #available(macOS 26, *) {
                let transcriber = try await AppleLocaleReservations.prepare(
                    locale: Locale(identifier: locale)
                )
                let request = try await AssetInventory.assetInstallationRequest(
                    supporting: [transcriber]
                )
                return request == nil
            }
        #endif
        return false
    }

    /// Install assets for a locale, reporting progress.
    ///
    /// No-op when already installed. Reports `Progress.fractionCompleted`
    /// (nil until `totalUnitCount > 0`).
    public static func installAssets(
        locale: String,
        progress: @escaping @Sendable (Double?) -> Void
    ) async throws {
        guard case .available = availability() else {
            throw TranscriptionError.engineUnavailable(
                "Apple Speech requires macOS 26 or later"
            )
        }
        #if canImport(Speech)
            if #available(macOS 26, *) {
                let transcriber = try await AppleLocaleReservations.prepare(
                    locale: Locale(identifier: locale)
                )
                guard let request = try await AssetInventory.assetInstallationRequest(
                    supporting: [transcriber]
                ) else {
                    log.info("Assets already installed for locale \(locale)")
                    return
                }

                log.info("Installing Apple speech assets for locale \(locale)")

                // Observe progress on a background task. The observation
                // fires on an arbitrary thread; the @Sendable callback
                // lets the caller dispatch to @MainActor if needed.
                let observationTask = Task.detached {
                    let requestProgress = request.progress
                    while !Task.isCancelled {
                        let fraction: Double? = if requestProgress.totalUnitCount > 0 {
                            requestProgress.fractionCompleted
                        } else {
                            nil
                        }
                        progress(fraction)
                        try await Task.sleep(for: .milliseconds(250))
                    }
                }

                do {
                    try await request.downloadAndInstall()
                    observationTask.cancel()
                    progress(1.0)
                    log.info("Asset installation complete for locale \(locale)")
                } catch {
                    observationTask.cancel()
                    log.error("Asset installation failed for locale \(locale): \(error)")
                    throw TranscriptionError.downloadFailed(
                        "Apple speech assets: \(error.localizedDescription)"
                    )
                }
                return
            }
        #endif
        throw TranscriptionError.engineUnavailable(
            "Apple Speech requires macOS 26 or later"
        )
    }
}
