import CoreAudio
import Foundation

struct AudioProcess: Identifiable, Sendable {
    let id: AudioObjectID
    let bundleID: String
    let pid: pid_t
    let isRunningInput: Bool
    let isRunningOutput: Bool

    var isMeetingApp: Bool {
        Self.knownMeetingBundleIDs.contains(bundleID)
    }

    var displayName: String {
        if let name = Self.meetingAppNames[bundleID] {
            return name
        }
        return bundleID
    }

    static let knownMeetingBundleIDs: Set<String> = [
        "us.zoom.xos",
        "com.microsoft.teams2",
        "com.google.Chrome",
        "com.tinyspeck.slackmacgap",
        "com.cisco.webexmeetingsapp",
        "com.hnc.Discord",
        "com.apple.FaceTime",
        "com.apple.Safari",
        "company.thebrowser.Browser",
    ]

    static let meetingAppNames: [String: String] = [
        "us.zoom.xos": "Zoom",
        "com.microsoft.teams2": "Microsoft Teams",
        "com.google.Chrome": "Google Chrome",
        "com.tinyspeck.slackmacgap": "Slack",
        "com.cisco.webexmeetingsapp": "Cisco Webex",
        "com.hnc.Discord": "Discord",
        "com.apple.FaceTime": "FaceTime",
        "com.apple.Safari": "Safari",
        "company.thebrowser.Browser": "Arc Browser",
    ]
}
