import Foundation

/// V1 implementation backed by compiled-in watchlists and regex patterns.
///
/// Productionized from `AudioProcess.knownMeetingBundleIDs` (AudioCapture)
/// and `ConferenceDetector` (EventKitLab). Regex instances are compiled once
/// at init and cached for the lifetime of the catalog.
public struct BundledMeetingCatalog: MeetingCatalog {
    // MARK: - Init

    public init() {}

    // MARK: - Bundle ID lookups

    public func displayName(forBundleID id: String) -> String? {
        // For helpers, return the parent's display name
        if let parentID = Self.helperToParent[id] {
            return Self.appNames[parentID]
        }
        return Self.appNames[id]
    }

    public func isMeetingApp(bundleID: String) -> Bool {
        Self.meetingBundleIDs.contains(bundleID)
    }

    public func parentBundleID(forHelperBundleID id: String) -> String? {
        Self.helperToParent[id]
    }

    // MARK: - Conference detection

    public func conferenceMatch(
        inURL url: URL?,
        location: String?,
        notes: String?
    ) -> (platform: String, url: URL)? {
        // Priority: url > location > notes (matches EventKitLab)
        if let url, let result = matchInText(url.absoluteString) {
            return result
        }
        if let location, let result = matchInText(location) {
            return result
        }
        if let notes, let result = matchInText(notes) {
            return result
        }
        return nil
    }

    // MARK: - Private

    private func matchInText(_ text: String) -> (platform: String, url: URL)? {
        for entry in Self.compiledPatterns {
            let range = NSRange(text.startIndex..., in: text)
            if let match = entry.regex.firstMatch(in: text, range: range),
               let matchRange = Range(match.range, in: text),
               let matchedURL = URL(string: String(text[matchRange]))
            {
                return (entry.platform, matchedURL)
            }
        }
        return nil
    }

    // MARK: - Static data

    /// Known meeting app bundle IDs (user-facing + helpers).
    /// Source: `research/audio/meeting_app_bundle_ids.md` and
    /// `AudioProcess.knownMeetingBundleIDs`.
    private static let meetingBundleIDs: Set<String> = [
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

    /// Human-readable names for user-facing apps only.
    private static let appNames: [String: String] = [
        "us.zoom.xos": "Zoom",
        "com.microsoft.teams2": "Microsoft Teams",
        "com.google.Chrome": "Google Chrome",
        "com.tinyspeck.slackmacgap": "Slack",
        "com.cisco.webexmeetingsapp": "Cisco Webex",
        "com.hnc.Discord": "Discord",
        "com.apple.FaceTime": "FaceTime",
        "com.apple.Safari": "Safari",
        "company.thebrowser.Browser": "Arc Browser"
    ]

    /// Helper-process to user-facing parent mapping.
    private static let helperToParent: [String: String] = [
        "com.apple.WebKit.GPU": "com.apple.Safari",
        "com.apple.avconferenced": "com.apple.FaceTime",
        "com.tinyspeck.slackmacgap.helper": "com.tinyspeck.slackmacgap"
    ]

    // MARK: - Compiled regex patterns (cached)

    private struct CompiledPattern {
        let platform: String
        let regex: NSRegularExpression
    }

    private static let compiledPatterns: [CompiledPattern] = {
        let patterns: [(String, String)] = [
            ("Zoom", #"https?://[\w.-]*zoom\.us/j/\d+[^\s]*"#),
            ("Google Meet", #"https?://meet\.google\.com/[a-z-]+"#),
            ("Microsoft Teams", #"https?://teams\.microsoft\.com/l/meetup-join/[^\s]+"#),
            ("Cisco Webex", #"https?://[\w.-]*webex\.com/[^\s]+"#),
            ("Slack Huddle", #"https?://app\.slack\.com/huddle/[^\s]+"#)
        ]
        return patterns.compactMap { platform, pattern in
            guard let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive) else {
                assertionFailure("Failed to compile conference regex for \(platform): \(pattern)")
                return nil
            }
            return CompiledPattern(platform: platform, regex: regex)
        }
    }()
}
