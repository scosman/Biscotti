import Foundation
import Testing
@testable import MeetingDetailUI

@Suite("SpeakerLink URL construction and parsing")
struct SpeakerLinkTests {
    @Test("round-trips speaker ID through URL")
    func roundTrip() {
        let url = SpeakerLink.url(speakerID: 3)
        let parsed = SpeakerLink.speakerID(from: url)
        #expect(parsed == 3)
    }

    @Test("round-trips speaker ID 0")
    func roundTripZero() {
        let url = SpeakerLink.url(speakerID: 0)
        let parsed = SpeakerLink.speakerID(from: url)
        #expect(parsed == 0)
    }

    @Test("URL has correct scheme and host")
    func urlFormat() {
        let url = SpeakerLink.url(speakerID: 5)
        #expect(url.scheme == "biscotti")
        #expect(url.host == "speaker")
    }

    @Test("returns nil for non-speaker URL")
    func nonSpeakerURL() {
        let seekURL = SeekLink.url(seconds: 42.0)
        #expect(SpeakerLink.speakerID(from: seekURL) == nil)
    }

    @Test("returns nil for completely unrelated URL")
    func unrelatedURL() throws {
        let url = try #require(URL(string: "https://example.com"))
        #expect(SpeakerLink.speakerID(from: url) == nil)
    }

    @Test("returns nil for speaker URL without id parameter")
    func missingIDParam() throws {
        let url = try #require(URL(string: "biscotti://speaker"))
        #expect(SpeakerLink.speakerID(from: url) == nil)
    }

    @Test("returns nil for speaker URL with non-integer id")
    func nonIntegerID() throws {
        let url = try #require(URL(string: "biscotti://speaker?id=abc"))
        #expect(SpeakerLink.speakerID(from: url) == nil)
    }
}
