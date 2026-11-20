import AppKit
import Foundation
import Permissions
import UICapture

// One model for every permission Biscotti needs, so the launch
// prompt and Settings behave the same way: each permission has a status and
// one "Grant…" action that asks macOS when it still can, and otherwise opens
// the right System Settings pane.

public enum AppPermission: String, CaseIterable, Identifiable, Sendable {
    case microphone
    case systemAudio
    case accessibility
    case notifications
    case calendar

    public var id: String {
        rawValue
    }

    public var title: String {
        switch self {
        case .microphone: "Microphone"
        case .systemAudio: "System Audio Recording"
        case .accessibility: "Accessibility"
        case .notifications: "Notifications"
        case .calendar: "Calendar"
        }
    }

    /// Why Biscotti needs it, in one line.
    public var purpose: String {
        switch self {
        case .microphone: "Records your side of the meeting."
        case .systemAudio: "Records the other participants (the meeting app's sound)."
        case .accessibility: "Reads participant names from the meeting window to name speakers."
        case .notifications: "Lets you stop automatic recordings and shows export results."
        case .calendar: "Titles meetings and suggests attendee names."
        }
    }
}

public enum AppPermissionStatus: Sendable, Equatable {
    case granted
    /// macOS hasn't asked yet; Grant shows the system prompt.
    case notAsked
    /// Turned off, or asked without success; Grant opens System Settings.
    case blocked

    public var title: String {
        switch self {
        case .granted: "Granted"
        case .notAsked: "Not granted"
        case .blocked: "Off in System Settings"
        }
    }
}

public extension AppCore {
    func status(of permission: AppPermission) -> AppPermissionStatus {
        switch permission {
        case .microphone: Self.map(permissions.microphone)
        case .notifications: Self.map(permissions.notifications)
        case .calendar: Self.map(permissions.calendar)
        case .systemAudio:
            switch permissions.systemAudio {
            case .approved: .granted
            case .notRequested: .notAsked
            case .requestedNotVerified: .blocked
            }
        case .accessibility:
            // macOS doesn't say whether it has asked; the first Grant shows
            // its prompt and opens the pane either way.
            UICaptureController.hasAccessibilityPermission ? .granted : .notAsked
        }
    }

    /// Permissions the launch prompt asks about: anything never asked, plus
    /// anything required for recording that is off. Calendar and
    /// notifications that were deliberately turned off aren't nagged about.
    var permissionsNeedingAttention: [AppPermission] {
        AppPermission.allCases.filter { permission in
            if permission == .accessibility, !automation.settings.captureMeetingUI {
                return false
            }
            switch status(of: permission) {
            case .granted: return false
            case .notAsked: return true
            case .blocked: return [.microphone, .systemAudio, .accessibility].contains(permission)
            }
        }
    }

    /// What the launch prompt lists; empty when it's closed.
    var launchPermissionPrompt: [AppPermission] {
        get { automation.missingPermissions.compactMap(AppPermission.init(rawValue:)) }
        set { automation.missingPermissions = newValue.map(\.rawValue) }
    }

    /// The single action behind every Grant button.
    func grant(_ permission: AppPermission) async {
        let status = status(of: permission)
        guard status != .granted else { return }
        if status == .notAsked {
            switch permission {
            case .microphone: await permissions.requestMicrophone()
            case .systemAudio: await requestSystemAudioPermission()
            case .notifications: _ = await permissions.requestNotifications()
            case .calendar:
                let result = await calendar.requestAccess()
                let state: PermissionState = switch result {
                case .authorized: .authorized
                case .denied, .restricted: .denied
                case .notDetermined: .notDetermined
                }
                permissions.noteCalendar(state)
            case .accessibility:
                UICaptureController.promptForAccessibilityIfNeeded()
                openSystemSettings(for: .accessibility)
            }
            await refreshAllPermissions()
            return
        }
        openSystemSettings(for: permission)
    }

    func openSystemSettings(for permission: AppPermission) {
        switch permission {
        case .microphone: NSWorkspace.shared.open(permissions.settingsURL(for: .microphone))
        case .systemAudio: permissions.openSystemAudioSettings()
        case .notifications: NSWorkspace.shared.open(permissions.settingsURL(for: .notifications))
        case .calendar: NSWorkspace.shared.open(permissions.settingsURL(for: .calendar))
        case .accessibility: UICaptureController.openAccessibilitySettings()
        }
    }

    private static func map(_ state: PermissionState) -> AppPermissionStatus {
        switch state {
        case .authorized: .granted
        case .notDetermined: .notAsked
        case .denied: .blocked
        }
    }
}
