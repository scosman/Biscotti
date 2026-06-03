import XCTest

@testable import EventKitLab

final class ConferenceDetectorTests: XCTestCase {
    // MARK: - Zoom

    func testDetectsZoomURL() {
        let notes = "Join the meeting: https://us02web.zoom.us/j/1234567890?pwd=abc123 See you there!"
        let result = ConferenceDetector.detect(url: nil, notes: notes, location: nil)
        XCTAssertNotNil(result)
        XCTAssertEqual(result?.platform, "zoom")
        XCTAssertTrue(result!.url.absoluteString.contains("zoom.us/j/1234567890"))
    }

    func testDetectsZoomURLInLocation() {
        let result = ConferenceDetector.detect(
            url: nil,
            notes: nil,
            location: "https://zoom.us/j/9876543210"
        )
        XCTAssertNotNil(result)
        XCTAssertEqual(result?.platform, "zoom")
    }

    // MARK: - Google Meet

    func testDetectsGoogleMeetURL() {
        let notes = "Join at https://meet.google.com/abc-defg-hij"
        let result = ConferenceDetector.detect(url: nil, notes: notes, location: nil)
        XCTAssertNotNil(result)
        XCTAssertEqual(result?.platform, "meet")
        XCTAssertEqual(result?.url.absoluteString, "https://meet.google.com/abc-defg-hij")
    }

    func testDetectsGoogleMeetNonThreeSegmentURL() {
        // Some Meet URLs use different segment structures (e.g. lookup codes)
        let notes = "Join at https://meet.google.com/abcdefghij"
        let result = ConferenceDetector.detect(url: nil, notes: notes, location: nil)
        XCTAssertNotNil(result)
        XCTAssertEqual(result?.platform, "meet")
        XCTAssertEqual(result?.url.absoluteString, "https://meet.google.com/abcdefghij")
    }

    // MARK: - Microsoft Teams

    func testDetectsTeamsURL() {
        let notes = "Click here: https://teams.microsoft.com/l/meetup-join/19%3ameeting_abc123"
        let result = ConferenceDetector.detect(url: nil, notes: notes, location: nil)
        XCTAssertNotNil(result)
        XCTAssertEqual(result?.platform, "teams")
    }

    // MARK: - Webex

    func testDetectsWebexURL() {
        let notes = "Webex: https://company.webex.com/meet/john.doe"
        let result = ConferenceDetector.detect(url: nil, notes: notes, location: nil)
        XCTAssertNotNil(result)
        XCTAssertEqual(result?.platform, "webex")
    }

    // MARK: - Slack Huddle

    func testDetectsSlackHuddleURL() {
        let notes = "Huddle link: https://app.slack.com/huddle/T12345/C67890"
        let result = ConferenceDetector.detect(url: nil, notes: notes, location: nil)
        XCTAssertNotNil(result)
        XCTAssertEqual(result?.platform, "slack")
    }

    // MARK: - URL field takes priority

    func testURLFieldTakesPriority() {
        let url = URL(string: "https://meet.google.com/aaa-bbbb-ccc")!
        let result = ConferenceDetector.detect(
            url: url,
            notes: "https://zoom.us/j/111",
            location: nil
        )
        XCTAssertNotNil(result)
        XCTAssertEqual(result?.platform, "meet")
    }

    // MARK: - Location checked before notes

    func testLocationCheckedBeforeNotes() {
        let result = ConferenceDetector.detect(
            url: nil,
            notes: "Some notes without a link",
            location: "https://zoom.us/j/999"
        )
        XCTAssertNotNil(result)
        XCTAssertEqual(result?.platform, "zoom")
    }

    // MARK: - No match

    func testNoMatchReturnsNil() {
        let result = ConferenceDetector.detect(
            url: nil,
            notes: "Just a regular meeting, no link.",
            location: "Conference Room B"
        )
        XCTAssertNil(result)
    }

    func testNilInputsReturnNil() {
        let result = ConferenceDetector.detect(url: nil, notes: nil, location: nil)
        XCTAssertNil(result)
    }

    func testEmptyStringsReturnNil() {
        let result = ConferenceDetector.detect(url: nil, notes: "", location: "")
        XCTAssertNil(result)
    }

    func testNonConferenceURLReturnsNil() {
        let url = URL(string: "https://www.google.com/calendar/event?id=abc")!
        let result = ConferenceDetector.detect(url: url, notes: nil, location: nil)
        XCTAssertNil(result)
    }
}
