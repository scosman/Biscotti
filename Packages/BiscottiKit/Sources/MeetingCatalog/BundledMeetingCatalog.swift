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
    /// Source: `research/meeting_apps/README.md` and
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
            // Zoom: /j/ requires digits (meeting ID); /my/, /w/, /s/ accept slugs. + zoomgov
            ("Zoom", #"https?://[\w.-]*\.?zoom(gov)?\.us/(?:j/\d+[^\s]*|(?:my|w|s)/[^\s]+)"#),
            ("Zoom", #"https?://[\w.-]*\.?zoomgov\.com/(?:j/\d+[^\s]*|(?:my|w|s)/[^\s]+)"#),

            // Google Meet: 3-4-3 lowercase letter code
            ("Google Meet", #"https?://meet\.google\.com/[a-z]{3}-[a-z]{4}-[a-z]{3}"#),

            // Microsoft Teams: legacy /l/meetup-join, new /meet/, consumer teams.live.com, gov
            ("Microsoft Teams",
             #"https?://(?:teams\.microsoft\.com/(?:l/meetup-join|meet)/|teams\.live\.com/meet/|(?:gov|dod)\.teams\.microsoft\.us/l/meetup-join/)[^\s]+"#),

            // Cisco Webex: personal room, scheduled (j.php), joinservice
            ("Cisco Webex",
             #"https?://[\w.-]+\.webex\.com/(?:meet/[^\s]+|[^\s]*j\.php\?[^\s]+|wbxmjs/joinservice/[^\s]+)"#),

            // Slack Huddle (UNVERIFIED — see research/meeting_apps/README.md)
            ("Slack Huddle", #"https?://app\.slack\.com/huddle/[^\s]+"#),

            // GoTo Meeting: gotomeeting.com, gotomeet.me, meet.goto.com
            ("GoTo Meeting",
             #"https?://(?:global\.gotomeeting\.com/join/\d{9}|gotomeet\.me/[A-Za-z0-9._~-]+|meet\.goto\.com/[A-Za-z0-9._~-]+)(?:[?#][^\s]*)?"#),

            // RingCentral: v.ringcentral.com, video.ringcentral.com, meetings.ringcentral.com
            ("RingCentral",
             #"https?://(?:v|video|meetings)\.ringcentral\.com/(?:join|j)/[A-Za-z0-9]+"#),

            // Jitsi Meet: meet.jit.si (public instance only; self-hosted = infinite domains)
            ("Jitsi Meet", #"https?://meet\.jit\.si/[A-Za-z0-9_-]+"#),

            // 8x8 / Jitsi: 8x8.vc (shared by 8x8 Work and JaaS-hosted Jitsi)
            ("8x8 / Jitsi", #"https?://(?:[a-z]+\.)?8x8\.vc/[^\s/?#]+/[^\s/?#]+"#),

            // Zoho Meeting: meeting.zoho.{com,eu,in,com.au,jp}
            ("Zoho Meeting", #"https?://meeting\.zoho\.(com|eu|in|com\.au|jp)/join\?key=\d+"#),

            // Dialpad: meetings.dialpad.com + legacy uberconference.com
            ("Dialpad", #"https?://meetings\.dialpad\.com/(room/)?[A-Za-z0-9][A-Za-z0-9._-]{3,}"#),
            ("Dialpad", #"https?://(www\.)?uberconference\.com/[A-Za-z0-9][A-Za-z0-9._-]{3,}"#),

            // Vonage: meetings.vonage.com (6-12 digit meeting code)
            ("Vonage", #"https?://meetings\.vonage\.com/[0-9]{6,12}"#),

            // FaceTime: facetime.apple.com/join# (hash fragment holds key material)
            ("FaceTime", #"https?://facetime\.apple\.com/join#[^\s]+"#),

            // Whereby: whereby.com room links (browser-only)
            ("Whereby", #"https?://([a-zA-Z0-9-]+\.)?whereby\.com/(?!information|blog|user|sitemap)[a-zA-Z0-9][a-zA-Z0-9_-]+"#),

            // ClickMeeting / ClickWebinar (bundle ID unverified; link format is solid)
            ("ClickMeeting", #"https?://[A-Za-z0-9-]+\.click(?:meeting|webinar)\.com/[A-Za-z0-9_-]+"#)
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
