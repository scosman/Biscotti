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

    /// Temporary adapter mapping to `PermissionState` for UI call sites
    /// that still use the shared permission row helper.
    ///
    /// - `.notRequested` -> `.notDetermined` (shows "Request Access")
    /// - `.requestedNotVerified` -> `.notDetermined` (shows "Request Access"
    ///   rather than the misleading "Open Settings / denied" prompt, since the
    ///   state is intentionally ambiguous -- user may have granted but we
    ///   couldn't verify, or may not have granted yet)
    /// - `.approved` -> `.authorized` (shows checkmark)
    ///
    /// - Note: TODO Phase 3 — remove this adapter when the system-audio row
    ///   gets its own dedicated UI with Retry / Validate / Fix permissions.
    public var asPermissionState: PermissionState {
        switch self {
        case .notRequested: .notDetermined
        case .requestedNotVerified: .notDetermined
        case .approved: .authorized
        }
    }
}
