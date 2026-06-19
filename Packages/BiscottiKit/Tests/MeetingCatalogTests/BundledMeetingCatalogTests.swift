import Foundation
import MeetingCatalog
import Testing

@Suite("BundledMeetingCatalog")
struct BundledMeetingCatalogTests {
    let catalog = BundledMeetingCatalog()

    // MARK: - isMeetingApp (parameterized)

    @Test("Recognized meeting app bundle IDs", arguments: [
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
        "com.zoho.meeting",
        "com.hnc.Discord",
        "com.apple.FaceTime",
        "com.tinyspeck.slackmacgap",
        "com.tinyspeck.slackmacgap.helper",
        "com.google.Chrome",
        "com.apple.Safari",
        "company.thebrowser.Browser",
        "com.apple.avconferenced",
        "com.apple.WebKit.GPU"
    ])
    func isMeetingApp(bundleID: String) {
        #expect(catalog.isMeetingApp(bundleID: bundleID))
    }

    @Test("Unknown bundle IDs are not meeting apps", arguments: [
        "com.example.notes",
        "com.apple.Music",
        "",
    ])
    func unknownNotMeetingApp(bundleID: String) {
        #expect(!catalog.isMeetingApp(bundleID: bundleID))
    }

    // MARK: - displayName (parameterized)

    @Test("Display name for bundle ID", arguments: [
        ("us.zoom.xos", "Zoom"),
        ("com.microsoft.teams2", "Microsoft Teams"),
        ("Cisco-Systems.Spark", "Cisco Webex"),
        ("com.cisco.webexmeetingsapp", "Cisco Webex"),
        ("com.logmein.GoToMeeting", "GoTo Meeting"),
        ("com.logmein.goto", "GoTo"),
        ("com.ringcentral.glip", "RingCentral"),
        ("org.jitsi.jitsi-meet", "Jitsi Meet"),
        ("com.electron.8x8---virtual-office", "8x8 Work"),
        ("com.electron.dialpad", "Dialpad"),
        ("com.vonage.vbc", "Vonage"),
        ("com.zoho.meeting", "Zoho Meeting"),
        ("com.google.Chrome", "Google Chrome"),
        ("com.tinyspeck.slackmacgap", "Slack"),
        ("com.hnc.Discord", "Discord"),
        ("com.apple.FaceTime", "FaceTime"),
        ("com.apple.Safari", "Safari"),
        ("company.thebrowser.Browser", "Arc Browser"),
    ])
    func displayName(bundleID: String, expected: String) {
        #expect(catalog.displayName(forBundleID: bundleID) == expected)
    }

    @Test("Helpers resolve to parent display name", arguments: [
        ("com.apple.WebKit.GPU", "Safari"),
        ("com.apple.avconferenced", "FaceTime"),
        ("com.tinyspeck.slackmacgap.helper", "Slack"),
    ])
    func helperDisplayName(helperID: String, expectedParentName: String) {
        #expect(catalog.displayName(forBundleID: helperID) == expectedParentName)
    }

    @Test("Display name for unknown bundle ID is nil")
    func displayNameUnknown() {
        #expect(catalog.displayName(forBundleID: "com.example.notes") == nil)
    }

    // MARK: - parentBundleID (parameterized)

    @Test("Helper-to-parent mapping", arguments: [
        ("com.apple.WebKit.GPU", "com.apple.Safari"),
        ("com.apple.avconferenced", "com.apple.FaceTime"),
        ("com.tinyspeck.slackmacgap.helper", "com.tinyspeck.slackmacgap"),
    ])
    func helperToParent(helperID: String, expectedParentID: String) {
        #expect(catalog.parentBundleID(forHelperBundleID: helperID) == expectedParentID)
    }

    @Test("User-facing apps have no parent mapping", arguments: [
        "us.zoom.xos",
        "com.apple.FaceTime",
        "com.example.notes",
    ])
    func noParentMapping(bundleID: String) {
        #expect(catalog.parentBundleID(forHelperBundleID: bundleID) == nil)
    }
}
