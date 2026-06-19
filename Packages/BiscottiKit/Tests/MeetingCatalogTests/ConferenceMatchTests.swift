import Foundation
import MeetingCatalog
import Testing

@Suite("BundledMeetingCatalog — Conference Match")
struct ConferenceMatchTests {
    let catalog = BundledMeetingCatalog()

    // MARK: - Positive matches (parameterized)

    @Test("Detects conference link for platform", arguments: [
        // Zoom
        ("https://us04web.zoom.us/j/12345678?pwd=abc", "Zoom"),
        ("https://zoom.us/my/johndoe", "Zoom"),
        ("https://zoom.us/w/12345678901?tk=abc", "Zoom"),
        ("https://zoom.us/s/12345678901", "Zoom"),
        ("https://zoomgov.com/j/1234567890", "Zoom"),
        ("https://company.zoom.us/j/1234567890", "Zoom"),

        // Google Meet
        ("https://meet.google.com/abc-defg-hij", "Google Meet"),

        // Microsoft Teams
        ("https://teams.microsoft.com/l/meetup-join/abc123", "Microsoft Teams"),
        ("https://teams.microsoft.com/meet/abc123def?p=HashedPasscode", "Microsoft Teams"),
        ("https://teams.live.com/meet/9425716001426", "Microsoft Teams"),
        ("https://gov.teams.microsoft.us/l/meetup-join/abc123", "Microsoft Teams"),

        // Cisco Webex
        ("https://example.webex.com/meet/room1", "Cisco Webex"),
        ("https://acme.webex.com/acme/j.php?MTID=m12345", "Cisco Webex"),

        // Slack Huddle
        ("https://app.slack.com/huddle/T123/C456", "Slack Huddle"),

        // GoTo Meeting
        ("https://global.gotomeeting.com/join/850393077", "GoTo Meeting"),
        ("https://gotomeet.me/JohnSmith", "GoTo Meeting"),
        ("https://meet.goto.com/123456789", "GoTo Meeting"),

        // RingCentral
        ("https://v.ringcentral.com/join/469909326", "RingCentral"),
        ("https://video.ringcentral.com/join/123456789", "RingCentral"),
        ("https://meetings.ringcentral.com/j/1234567890", "RingCentral"),

        // Jitsi Meet
        ("https://meet.jit.si/MyTeamStandup", "Jitsi Meet"),

        // 8x8 / Jitsi
        ("https://8x8.vc/acmejets/mel.black", "8x8 / Jitsi"),
        ("https://8x8.vc/vpaas-magic-cookie-abc123/MyRoom", "8x8 / Jitsi"),

        // Zoho Meeting
        ("https://meeting.zoho.com/join?key=1234567890", "Zoho Meeting"),
        ("https://meeting.zoho.eu/join?key=1234567890", "Zoho Meeting"),

        // Dialpad
        ("https://meetings.dialpad.com/janedoe", "Dialpad"),
        ("https://meetings.dialpad.com/room/budgetreview", "Dialpad"),
        ("https://www.uberconference.com/strategicearth", "Dialpad"),

        // Vonage
        ("https://meetings.vonage.com/982515622", "Vonage"),

        // FaceTime
        ("https://facetime.apple.com/join#v=1&p=BASE64&k=BASE64", "FaceTime"),

        // Whereby
        ("https://whereby.com/my-room", "Whereby"),
        ("https://mycompany.whereby.com/standup", "Whereby"),

        // ClickMeeting
        ("https://acme.clickmeeting.com/demo-room", "ClickMeeting"),
        ("https://corp.clickwebinar.com/training", "ClickMeeting")
    ])
    func detectsConferenceLink(urlString: String, expectedPlatform: String) throws {
        let url = try #require(URL(string: urlString))
        let result = catalog.conferenceMatch(inURL: url, location: nil, notes: nil)
        #expect(result?.platform == expectedPlatform)
    }

    // MARK: - Negative matches (parameterized)

    @Test("Rejects non-meeting URLs", arguments: [
        // Zoom /j/ requires digits — non-numeric slug must not match
        "https://zoom.us/j/nourl",
        "https://zoom.us/j/abc",

        // Google Meet non-meeting paths
        "https://meet.google.com/new",
        "https://meet.google.com/landing",

        // Webex marketing pages
        "https://www.webex.com/pricing",

        // Whereby marketing paths
        "https://whereby.com/information",
        "https://whereby.com/blog",
        "https://whereby.com/user",
        "https://whereby.com/sitemap",

        // Generic URLs
        "https://example.com/meeting"
    ])
    func rejectsNonMeetingURL(urlString: String) {
        let result = catalog.conferenceMatch(
            inURL: URL(string: urlString),
            location: nil,
            notes: nil
        )
        #expect(result == nil)
    }

    // MARK: - Detection from location and notes

    @Test("Detects conference link in location field")
    func detectsInLocation() {
        let result = catalog.conferenceMatch(
            inURL: nil,
            location: "https://meet.google.com/abc-defg-hij",
            notes: nil
        )
        #expect(result?.platform == "Google Meet")
    }

    @Test("Detects conference link in notes field")
    func detectsInNotes() {
        let result = catalog.conferenceMatch(
            inURL: nil,
            location: nil,
            notes: "Join here: https://teams.microsoft.com/l/meetup-join/abc123"
        )
        #expect(result?.platform == "Microsoft Teams")
    }

    // MARK: - Priority

    @Test("URL takes priority over location and notes")
    func urlPriority() throws {
        let url = try #require(URL(string: "https://us04web.zoom.us/j/12345678"))
        let result = catalog.conferenceMatch(
            inURL: url,
            location: "https://meet.google.com/abc-defg-hij",
            notes: nil
        )
        #expect(result?.platform == "Zoom")
    }

    @Test("Location takes priority over notes")
    func locationPriority() {
        let result = catalog.conferenceMatch(
            inURL: nil,
            location: "https://meet.google.com/abc-defg-hij",
            notes: "Join here: https://teams.microsoft.com/l/meetup-join/abc123"
        )
        #expect(result?.platform == "Google Meet")
    }

    @Test("No conference link returns nil")
    func noMatch() {
        let result = catalog.conferenceMatch(
            inURL: URL(string: "https://example.com/meeting"),
            location: "Room 42",
            notes: "Bring your laptop"
        )
        #expect(result == nil)
    }

    @Test("All nils returns nil")
    func allNil() {
        let result = catalog.conferenceMatch(inURL: nil, location: nil, notes: nil)
        #expect(result == nil)
    }
}
