import Foundation
import TranscriptionService

/// Configurable fake `AppleSpeechProviding` for tests.
///
/// Uses a reference-type backing store (`@unchecked Sendable`) so
/// mutations are visible through protocol existentials. All access
/// is confined to `@MainActor` test functions in practice.
public final class FakeAppleSpeech: AppleSpeechProviding, @unchecked Sendable {
    /// Availability returned by `availability()`.
    public var scriptedAvailability: AppleSpeechAvailability

    /// Locales returned by `supportedLocales()`.
    public var scriptedLocales: [String]

    /// Locale returned by `supportedLocale(equivalentTo:)`.
    public var scriptedEquivalent: String?

    /// Locales for which `assetsInstalled` returns true.
    public var installedLocales: Set<String>

    /// Error to throw from `installAssets`, if any.
    public var installError: (any Error)?

    /// Progress fractions to report during `installAssets`.
    public var scriptedProgressValues: [Double?]

    /// Number of times `installAssets` was called.
    public var installCallCount = 0

    public init(
        availability: AppleSpeechAvailability = .available,
        locales: [String] = ["en_US", "en_GB", "fr_FR"],
        equivalent: String? = "en_US",
        installed: Set<String> = ["en_US"],
        installError: (any Error)? = nil,
        progressValues: [Double?] = [0.5, 1.0]
    ) {
        scriptedAvailability = availability
        scriptedLocales = locales
        scriptedEquivalent = equivalent
        installedLocales = installed
        self.installError = installError
        scriptedProgressValues = progressValues
    }

    public func availability() -> AppleSpeechAvailability {
        scriptedAvailability
    }

    public func supportedLocales() async -> [String] {
        scriptedLocales
    }

    public func supportedLocale(equivalentTo _: String) async -> String? {
        scriptedEquivalent
    }

    public func assetsInstalled(locale: String) async -> Bool {
        installedLocales.contains(locale)
    }

    public func installAssets(
        locale _: String,
        progress: @escaping @Sendable (Double?) -> Void
    ) async throws {
        installCallCount += 1
        for value in scriptedProgressValues {
            progress(value)
        }
        if let installError {
            throw installError
        }
    }
}
