/// The permission state for system-audio capture.
///
/// System audio gets its own state type (distinct from the shared
/// `PermissionState`) because:
/// - There is **no `denied`** state: macOS exposes no API to distinguish
///   "denied" from "granted but silent," so we never claim denial.
/// - There is a **`requestedNotVerified`** state that collapses "prompt
///   pending," "denied," and "granted but unconfirmed."
///
/// Persisted to `UserDefaults` via `SystemAudioPermissionStore` so the
/// state survives relaunch.
public enum SystemAudioPermissionState: String, Sendable, CaseIterable, Equatable {
    /// Never probed. Initial launch state.
    case notRequested

    /// A probe has run (or is running) but approval was not confirmed.
    /// Collapses "prompt pending," "denied," and "granted but unconfirmed."
    case requestedNotVerified

    /// The tone-probe captured non-zero audio -- permission is granted.
    case approved

    /// Human-readable label for display in Settings and Onboarding.
    public var displayText: String {
        switch self {
        case .notRequested: "Not Requested"
        case .requestedNotVerified: "Not approved"
        case .approved: "Granted"
        }
    }

    // MARK: - Fix-permissions alert copy (shared by Settings, Onboarding, and Stage 3)

    /// Alert title for the "Fix permissions" flow.
    public static let fixPermissionsAlertTitle = "Allow Biscotti to record system audio"

    /// Alert body for the "Fix permissions" flow.
    public static let fixPermissionsAlertBody =
        "Biscotti couldn\u{2019}t confirm permission to record your computer\u{2019}s audio. "
            + "macOS doesn\u{2019}t let apps re-ask directly \u{2014} turn it on in "
            + "System Settings: Privacy & Security \u{2192} System Audio Recording, "
            + "enable Biscotti, then return and tap Retry."
}
