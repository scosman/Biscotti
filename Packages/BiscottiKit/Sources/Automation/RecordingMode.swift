import Foundation

/// How Biscotti responds when a meeting app starts using the microphone.
///
/// Chosen from the menu bar or Settings. Manual recording (menu bar, global
/// shortcut, main window) works in every mode, including `.paused`.
public enum RecordingMode: String, Codable, Sendable, CaseIterable, Identifiable {
    /// Start recording as soon as a meeting is detected, then show a
    /// notification that can stop or discard it.
    case automatic
    /// Show the "Meeting detected" notification and record only if the user
    /// accepts. This is upstream Biscotti's behavior.
    case ask
    /// No detection prompts, no calendar prompts, no automatic recording.
    case paused

    public var id: String {
        rawValue
    }

    /// Short label for menus and pickers.
    public var title: String {
        switch self {
        case .automatic: "Record Automatically"
        case .ask: "Ask Before Recording"
        case .paused: "Paused"
        }
    }

    /// One-line explanation for Settings.
    public var detail: String {
        switch self {
        case .automatic:
            "Recording starts when a meeting app uses your microphone. A notification lets you stop or discard it."
        case .ask:
            "A notification offers to record when a meeting is detected."
        case .paused:
            "Nothing is recorded or offered until you resume. Manual recording still works."
        }
    }
}

/// What to do with one meeting-detection event.
public enum DetectionResponse: Sendable, Equatable {
    case ignore
    case offerToRecord
    case recordAutomatically
}

/// Pure decision for a detection event, kept separate from `AppCore` so the
/// rules are unit tested.
public enum DetectionPolicy {
    /// - Parameters:
    ///   - mode: The current recording mode.
    ///   - bundleID: The detected app's resolved (parent) bundle ID.
    ///   - autoRecordInBrowsers: When false, browser detections fall back to
    ///     an offer instead of recording, because any site using the mic
    ///     (dictation, a mic test) looks the same as a browser meeting.
    ///   - monitorForMeetings: Upstream's "Monitor for Meetings" toggle,
    ///     which gates the offer notification.
    public static func response(
        mode: RecordingMode,
        bundleID: String,
        autoRecordInBrowsers: Bool,
        monitorForMeetings: Bool
    ) -> DetectionResponse {
        let offer: DetectionResponse = monitorForMeetings ? .offerToRecord : .ignore
        switch mode {
        case .paused:
            return .ignore
        case .ask:
            return offer
        case .automatic:
            if BrowserApps.isBrowser(bundleID), !autoRecordInBrowsers {
                return offer
            }
            return .recordAutomatically
        }
    }
}

/// Bundle IDs of web browsers and web-app containers that can host meetings
/// (Google Meet, Teams on the web, Zoom web client, Teams inside Ferdium).
/// Their mic use is often not a meeting, so automatic mode treats them
/// with care, and UI capture only reads them while they are using the mic.
public enum BrowserApps {
    public static let bundleIDs: Set<String> = [
        "com.google.Chrome",
        "com.apple.Safari",
        "company.thebrowser.Browser",
        "com.microsoft.edgemac",
        "org.mozilla.firefox",
        "com.brave.Browser",
        "org.ferdium.ferdium-app"
    ]

    public static func isBrowser(_ bundleID: String) -> Bool {
        bundleIDs.contains(bundleID)
    }

    public static let ferdium = "org.ferdium.ferdium-app"
    /// Stands for "all web browsers" in `captureExcludedApps`.
    public static let groupID = "web-browsers"
}

/// The meeting apps listed in Settings for the meeting-window capture.
public enum CaptureAppChoices {
    public struct Choice: Sendable, Identifiable, Equatable {
        public let id: String
        public let name: String
    }

    public static let all: [Choice] = [
        Choice(id: "com.microsoft.teams2", name: "Microsoft Teams"),
        Choice(id: "us.zoom.xos", name: "Zoom"),
        Choice(id: BrowserApps.ferdium, name: "Ferdium"),
        Choice(id: "com.cisco.webexmeetingsapp", name: "Webex"),
        Choice(id: "com.tinyspeck.slackmacgap", name: "Slack"),
        Choice(id: BrowserApps.groupID, name: "Web browsers (Chrome, Safari, Edge, Arc, Firefox, Brave)")
    ]
}
