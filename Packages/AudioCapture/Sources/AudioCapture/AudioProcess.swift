import CoreAudio
import Foundation

/// A snapshot of a single audio-using process as reported by Core Audio.
///
/// In the public API (Phase 2.3) this backs `ProcessAudioActivity`.
/// The `bundleID` is optional because Core Audio may report a process
/// whose bundle ID cannot be resolved.
public struct AudioProcess: Identifiable, Sendable, Equatable {
    public let id: AudioObjectID
    public let bundleID: String?
    public let pid: pid_t
    public let isRunningInput: Bool
    public let isRunningOutput: Bool

    public init(
        id: AudioObjectID,
        bundleID: String?,
        pid: pid_t,
        isRunningInput: Bool,
        isRunningOutput: Bool
    ) {
        self.id = id
        self.bundleID = bundleID
        self.pid = pid
        self.isRunningInput = isRunningInput
        self.isRunningOutput = isRunningOutput
    }

    /// Whether this process's bundle ID is in the seed watchlist of known
    /// meeting/conferencing apps.
    public var isMeetingApp: Bool {
        guard let bundleID else { return false }
        return Self.knownMeetingBundleIDs.contains(bundleID)
    }

    /// Human-readable name for known meeting apps; falls back to the bundle ID
    /// or a placeholder for nil bundle IDs.
    public var displayName: String {
        if let bundleID, let name = Self.meetingAppNames[bundleID] {
            return name
        }
        return bundleID ?? "Unknown (\(pid))"
    }

    // MARK: - Seed watchlist (from research/audio/meeting_app_bundle_ids.md)

    // NOTE: This hardcoded seed data is temporary. When MeetingDetection is built
    // (Project 5), this list moves to the RemoteConfig module per architecture.md,
    // enabling OTA updates without app releases.

    public static let knownMeetingBundleIDs: Set<String> = [
        "us.zoom.xos",
        "com.microsoft.teams2",
        "com.google.Chrome",
        "com.tinyspeck.slackmacgap",
        "com.tinyspeck.slackmacgap.helper",
        "com.cisco.webexmeetingsapp",
        "com.hnc.Discord",
        "com.apple.FaceTime",
        "com.apple.Safari",
        "company.thebrowser.Browser",
        "com.apple.avconferenced",
        "com.apple.WebKit.GPU"
    ]

    public static let meetingAppNames: [String: String] = [
        "us.zoom.xos": "Zoom",
        "com.microsoft.teams2": "Microsoft Teams",
        "com.google.Chrome": "Google Chrome",
        "com.tinyspeck.slackmacgap": "Slack",
        "com.tinyspeck.slackmacgap.helper": "Slack Huddle",
        "com.cisco.webexmeetingsapp": "Cisco Webex",
        "com.hnc.Discord": "Discord",
        "com.apple.FaceTime": "FaceTime",
        "com.apple.Safari": "Safari",
        "company.thebrowser.Browser": "Arc Browser",
        "com.apple.avconferenced": "avconferenced",
        "com.apple.WebKit.GPU": "WebKit (GPU Process)"
    ]
}
