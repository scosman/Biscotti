import Foundation
import MeetingCatalog
import Testing

@Suite("BundledMeetingCatalog")
struct BundledMeetingCatalogTests {
    let catalog = BundledMeetingCatalog()

    // MARK: - isMeetingApp

    @Test("Known meeting app bundle IDs are recognized")
    func knownMeetingApps() {
        #expect(catalog.isMeetingApp(bundleID: "us.zoom.xos"))
        #expect(catalog.isMeetingApp(bundleID: "com.microsoft.teams2"))
        #expect(catalog.isMeetingApp(bundleID: "com.apple.FaceTime"))
        #expect(catalog.isMeetingApp(bundleID: "com.tinyspeck.slackmacgap"))
        #expect(catalog.isMeetingApp(bundleID: "com.cisco.webexmeetingsapp"))
    }

    @Test("Helper processes are recognized as meeting apps")
    func helperProcessesRecognized() {
        #expect(catalog.isMeetingApp(bundleID: "com.apple.WebKit.GPU"))
        #expect(catalog.isMeetingApp(bundleID: "com.apple.avconferenced"))
        #expect(catalog.isMeetingApp(bundleID: "com.tinyspeck.slackmacgap.helper"))
    }

    @Test("Unknown bundle IDs are not meeting apps")
    func unknownNotMeetingApp() {
        #expect(!catalog.isMeetingApp(bundleID: "com.example.notes"))
        #expect(!catalog.isMeetingApp(bundleID: "com.apple.Music"))
        #expect(!catalog.isMeetingApp(bundleID: ""))
    }

    // MARK: - displayName

    @Test("Display names for known apps")
    func displayNamesKnownApps() {
        #expect(catalog.displayName(forBundleID: "us.zoom.xos") == "Zoom")
        #expect(catalog.displayName(forBundleID: "com.microsoft.teams2") == "Microsoft Teams")
        #expect(catalog.displayName(forBundleID: "com.apple.FaceTime") == "FaceTime")
        #expect(catalog.displayName(forBundleID: "com.tinyspeck.slackmacgap") == "Slack")
    }

    @Test("Display name for helper returns parent's name")
    func displayNameHelperReturnsParent() {
        #expect(catalog.displayName(forBundleID: "com.apple.WebKit.GPU") == "Safari")
        #expect(catalog.displayName(forBundleID: "com.apple.avconferenced") == "FaceTime")
        #expect(catalog.displayName(forBundleID: "com.tinyspeck.slackmacgap.helper") == "Slack")
    }

    @Test("Display name for unknown bundle ID is nil")
    func displayNameUnknown() {
        #expect(catalog.displayName(forBundleID: "com.example.notes") == nil)
    }

    // MARK: - parentBundleID

    @Test("Helper-to-parent mapping")
    func helperToParent() {
        #expect(catalog.parentBundleID(forHelperBundleID: "com.apple.WebKit.GPU") == "com.apple.Safari")
        #expect(catalog.parentBundleID(forHelperBundleID: "com.apple.avconferenced") == "com.apple.FaceTime")
        #expect(
            catalog.parentBundleID(forHelperBundleID: "com.tinyspeck.slackmacgap.helper")
                == "com.tinyspeck.slackmacgap"
        )
    }

    @Test("User-facing apps have no parent mapping")
    func userFacingAppsNoParent() {
        #expect(catalog.parentBundleID(forHelperBundleID: "us.zoom.xos") == nil)
        #expect(catalog.parentBundleID(forHelperBundleID: "com.apple.FaceTime") == nil)
        #expect(catalog.parentBundleID(forHelperBundleID: "com.example.notes") == nil)
    }

    // MARK: - conferenceMatch

    @Test("Detects Zoom link in URL")
    func conferenceZoom() throws {
        let url = try #require(URL(string: "https://us04web.zoom.us/j/12345678?pwd=abc"))
        let result = catalog.conferenceMatch(inURL: url, location: nil, notes: nil)
        #expect(result?.platform == "Zoom")
        #expect(result?.url.absoluteString.contains("zoom.us") == true)
    }

    @Test("Detects Google Meet link in location")
    func conferenceMeetInLocation() {
        let result = catalog.conferenceMatch(
            inURL: nil,
            location: "https://meet.google.com/abc-defg-hij",
            notes: nil
        )
        #expect(result?.platform == "Google Meet")
    }

    @Test("Detects Teams link in notes")
    func conferenceTeamsInNotes() {
        let result = catalog.conferenceMatch(
            inURL: nil,
            location: nil,
            notes: "Join here: https://teams.microsoft.com/l/meetup-join/abc123"
        )
        #expect(result?.platform == "Microsoft Teams")
    }

    @Test("Detects Webex link")
    func conferenceWebex() throws {
        let url = try #require(URL(string: "https://example.webex.com/meet/room1"))
        let result = catalog.conferenceMatch(inURL: url, location: nil, notes: nil)
        #expect(result?.platform == "Cisco Webex")
    }

    @Test("Detects Slack Huddle link")
    func conferenceSlack() throws {
        let url = try #require(URL(string: "https://app.slack.com/huddle/T123/C456"))
        let result = catalog.conferenceMatch(inURL: url, location: nil, notes: nil)
        #expect(result?.platform == "Slack Huddle")
    }

    @Test("URL takes priority over location and notes")
    func conferencePriorityURLFirst() throws {
        let url = try #require(URL(string: "https://us04web.zoom.us/j/12345678"))
        let result = catalog.conferenceMatch(
            inURL: url,
            location: "https://meet.google.com/abc-defg-hij",
            notes: nil
        )
        #expect(result?.platform == "Zoom")
    }

    @Test("Location takes priority over notes")
    func conferencePriorityLocationOverNotes() {
        let result = catalog.conferenceMatch(
            inURL: nil,
            location: "https://meet.google.com/abc-defg-hij",
            notes: "Join here: https://teams.microsoft.com/l/meetup-join/abc123"
        )
        #expect(result?.platform == "Google Meet")
    }

    @Test("No conference link returns nil")
    func conferenceNoMatch() {
        let result = catalog.conferenceMatch(
            inURL: URL(string: "https://example.com/meeting"),
            location: "Room 42",
            notes: "Bring your laptop"
        )
        #expect(result == nil)
    }

    @Test("All nils returns nil")
    func conferenceAllNil() {
        let result = catalog.conferenceMatch(inURL: nil, location: nil, notes: nil)
        #expect(result == nil)
    }
}
