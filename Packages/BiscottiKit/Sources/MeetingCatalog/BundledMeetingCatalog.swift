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
    /// Source: `specs/research/meeting_apps/README.md` and
    /// `AudioProcess.knownMeetingBundleIDs`.
    private static let meetingBundleIDs: Set<String> = [
        // Native meeting apps
        "us.zoom.xos",
        "com.microsoft.teams2",
        "Cisco-Systems.Spark",
        "com.cisco.webexmeetingsapp",
        "com.logmein.GoToMeeting",
        "com.logmein.goto",
        "com.ringcentral.glip",
        "org.jitsi.jitsi-meet",
        "com.electron.8x8---virtual-office",
        "com.electron.dialpad",
        "com.vonage.vbc",
        "com.zoho.meeting", // medium-confidence, web-sourced; verify on hardware
        "com.hnc.Discord",
        "com.apple.FaceTime",
        "com.tinyspeck.slackmacgap",
        "com.tinyspeck.slackmacgap.helper",

        // Browsers (host browser-only meetings: Google Meet, Whereby, etc.)
        "com.google.Chrome",
        "com.apple.Safari",
        "company.thebrowser.Browser",

        // System helpers (audio-routing daemons)
        "com.apple.avconferenced",
        "com.apple.WebKit.GPU"
    ]

    /// Human-readable names for user-facing apps only.
    private static let appNames: [String: String] = [
        "us.zoom.xos": "Zoom",
        "com.microsoft.teams2": "Microsoft Teams",
        "Cisco-Systems.Spark": "Cisco Webex",
        "com.cisco.webexmeetingsapp": "Cisco Webex",
        "com.logmein.GoToMeeting": "GoTo Meeting",
        "com.logmein.goto": "GoTo",
        "com.ringcentral.glip": "RingCentral",
        "org.jitsi.jitsi-meet": "Jitsi Meet",
        "com.electron.8x8---virtual-office": "8x8 Work",
        "com.electron.dialpad": "Dialpad",
        "com.vonage.vbc": "Vonage",
        "com.zoho.meeting": "Zoho Meeting",
        "com.google.Chrome": "Google Chrome",
        "com.tinyspeck.slackmacgap": "Slack",
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
            // Zoom: join-path prefixes; ID/slug unconstrained — matches numeric IDs and name-join links
            ("Zoom", #"https?://[\w.-]*\.?zoom\.us/(?:j|my|w|s|wc)/[^\s]+"#),
            ("Zoom", #"https?://[\w.-]*\.?zoomgov\.com/(?:j|my|w|s|wc)/[^\s]+"#),

            // Google Meet: 3-4-3 code or /lookup/<nickname>
            ("Google Meet", #"https?://meet\.google\.com/(?:lookup/[^\s]+|[a-z]{3}-[a-z]{4}-[a-z]{3})"#),

            // Microsoft Teams: legacy /l/meetup-join, new /meet/, consumer teams.live.com, gov
            ("Microsoft Teams",
             #"https?://(?:teams\.microsoft\.com/(?:l/meetup-join|meet)/|teams\.live\.com/meet/|(?:gov|dod)\.teams\.microsoft\.us/l/meetup-join/)[^\s]+"#),

            // Cisco Webex: any *.webex.com path — recall-first
            ("Cisco Webex", #"https?://(?:[\w.-]+\.)?webex\.com/[^\s]+"#),

            // Slack Huddle (UNVERIFIED — see specs/research/meeting_apps/README.md)
            ("Slack Huddle", #"https?://app\.slack\.com/huddle/[^\s]+"#),

            // GoTo Meeting: distinctive hosts, any join path accepted
            ("GoTo Meeting",
             #"https?://(?:global\.gotomeeting\.com/join/[^\s]+|gotomeet\.me/[^\s]+|meet\.goto\.com/[^\s]+)"#),

            // RingCentral: /join or /j path on distinctive subdomains
            ("RingCentral",
             #"https?://(?:v|video|meetings)\.ringcentral\.com/(?:join|j)/[^\s]+"#),

            // Jitsi Meet: meet.jit.si with optional namespace path segment
            ("Jitsi Meet", #"https?://meet\.jit\.si/[^\s/?#]+(?:/[^\s/?#]+)?"#),

            // 8x8 / Jitsi: 8x8.vc (shared by 8x8 Work and JaaS-hosted Jitsi)
            ("8x8 / Jitsi", #"https?://(?:[a-z]+\.)?8x8\.vc/[^\s/?#]+/[^\s/?#]+"#),

            // Zoho Meeting: meeting.zoho.* or meet.zoho.*, any path
            ("Zoho Meeting", #"https?://(?:meeting|meet)\.zoho\.(?:com|eu|in|com\.au|jp)/[^\s]+"#),

            // Dialpad: meetings.dialpad.com, uberconference.com, dialpad.com/meetings/
            ("Dialpad", #"https?://meetings\.dialpad\.com/(?:room/)?[^\s]+"#),
            ("Dialpad", #"https?://(?:www\.)?uberconference\.com/[^\s]+"#),
            ("Dialpad", #"https?://(?:www\.)?dialpad\.com/meetings/[^\s]+"#),

            // Vonage: meetings.vonage.com + freeconferencing.vonage.com
            ("Vonage", #"https?://(?:meetings|freeconferencing)\.vonage\.com/[^\s]+"#),

            // FaceTime: facetime.apple.com/join# (hash fragment holds key material)
            ("FaceTime", #"https?://facetime\.apple\.com/join#[^\s]+"#),

            // Whereby: room links; excludes known marketing paths
            ("Whereby",
             #"https?://(?:[a-zA-Z0-9-]+\.)?whereby\.com/(?!information|blog|user|sitemap|pricing|signin|download)[a-zA-Z0-9][^\s]*"#),

            // ClickMeeting / ClickWebinar: any room path on account subdomain
            ("ClickMeeting", #"https?://[A-Za-z0-9-]+\.click(?:meeting|webinar)\.com/[^\s]+"#)
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
