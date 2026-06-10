import AppKit
import Foundation

/// Unified, testable view of the system permissions the MVP needs.
///
/// Fully owns **microphone** (public TCC API via the `MicAuthorizing` seam).
/// **System audio** has no public status API; its state is reported by the
/// `Recording` module via `noteSystemAudio(_:)` after inference.
@MainActor @Observable
public final class Permissions {
    /// Current microphone permission state.
    public private(set) var microphone: PermissionState

    /// Current system-audio permission state (inferred by Recording, not TCC).
    public private(set) var systemAudio: PermissionState

    private let mic: any MicAuthorizing

    /// Creates a Permissions instance.
    /// - Parameter mic: The microphone authorization seam (defaults to the live implementation).
    public init(mic: any MicAuthorizing = LiveMicAuthorizer()) {
        self.mic = mic
        microphone = mic.status()
        systemAudio = .notDetermined
    }

    /// Re-reads the microphone status from the system.
    ///
    /// Call on app activation / window focus so the UI reflects
    /// permission changes made in System Settings.
    public func refresh() {
        microphone = mic.status()
    }

    /// Requests microphone permission. Returns `true` if granted.
    ///
    /// If already authorized, returns `true` without prompting.
    /// If denied, returns `false` (macOS won't re-prompt -- guide user to Settings).
    @discardableResult
    public func requestMicrophone() async -> Bool {
        switch microphone {
        case .authorized:
            return true
        case .denied:
            return false
        case .notDetermined:
            let granted = await mic.request()
            microphone = granted ? .authorized : .denied
            return granted
        }
    }

    /// Called by the Recording module to report inferred system-audio state.
    ///
    /// System audio has no public TCC status API; the Recording module infers
    /// denial from all-zero buffers and reports it here for the UI.
    public func noteSystemAudio(_ state: PermissionState) {
        systemAudio = state
    }

    /// Returns a URL that opens the correct System Settings pane for the given permission.
    public func settingsURL(for kind: PermissionKind) -> URL {
        switch kind {
        case .microphone:
            // Opens Privacy & Security > Microphone
            URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone")!

        case .systemAudio:
            // Opens Privacy & Security > Screen & System Audio Recording
            URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")!
        }
    }
}
