import Foundation
import Testing
@testable import MeetingDetailUI

@Suite("SeekLink")
struct SeekLinkTests {
    @Test("seconds parses valid seek URL")
    func parsesValidURL() throws {
        let url = try #require(URL(string: "biscotti://seek?t=14.0"))
        #expect(SeekLink.seconds(from: url) == 14.0)
    }

    @Test("seconds parses integer time")
    func parsesIntegerTime() throws {
        let url = try #require(URL(string: "biscotti://seek?t=90"))
        #expect(SeekLink.seconds(from: url) == 90.0)
    }

    @Test("seconds returns nil for wrong scheme")
    func wrongScheme() throws {
        let url = try #require(URL(string: "https://seek?t=14"))
        #expect(SeekLink.seconds(from: url) == nil)
    }

    @Test("seconds returns nil for wrong host")
    func wrongHost() throws {
        let url = try #require(URL(string: "biscotti://play?t=14"))
        #expect(SeekLink.seconds(from: url) == nil)
    }

    @Test("seconds returns nil for missing t parameter")
    func missingT() throws {
        let url = try #require(URL(string: "biscotti://seek"))
        #expect(SeekLink.seconds(from: url) == nil)
    }

    @Test("seconds returns nil for non-numeric t")
    func nonNumericT() throws {
        let url = try #require(URL(string: "biscotti://seek?t=abc"))
        #expect(SeekLink.seconds(from: url) == nil)
    }

    @Test("url builds valid seek URL")
    func urlBuildsCorrectly() {
        let url = SeekLink.url(seconds: 42.5)
        #expect(url.scheme == "biscotti")
        #expect(url.host == "seek")
        #expect(url.absoluteString.contains("t=42.5"))
    }

    @Test("url round-trips through seconds")
    func roundTrip() {
        let original: TimeInterval = 123.456
        let url = SeekLink.url(seconds: original)
        let parsed = SeekLink.seconds(from: url)
        #expect(parsed == original)
    }
}
