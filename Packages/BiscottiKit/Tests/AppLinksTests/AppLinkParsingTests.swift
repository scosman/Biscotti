import AppLinks
import Foundation
import Testing

/// Fixed UUID so failures are reproducible across runs.
private let meetingUUID = UUID(uuidString: "6B8F9C2A-1D3E-4F5A-9B2C-8E7D1A0F3B45")
    ?? UUID()

@Suite("AppLink — Parsing")
struct AppLinkParsingTests {
    @Test("Parses URL", arguments: [
        // Simple routes
        ("biscotti://home", AppLink.home),
        ("biscotti://meetings", AppLink.meetings),
        ("biscotti://settings", AppLink.settings),

        // Scheme and route are case-insensitive
        ("Biscotti://Home", AppLink.home),
        ("biscotti://MEETINGS", AppLink.meetings),

        // Unknown query parameters are ignored (forward compatibility)
        ("biscotti://home?foo=bar", AppLink.home),
        ("biscotti://meetings?x=1&y=2", AppLink.meetings),

        // meeting: default target is the Summary tab
        ("biscotti://meeting/\(meetingUUID.uuidString)", .meeting(id: meetingUUID, target: .tab(.summary))),
        ("biscotti://meeting/\(meetingUUID.uuidString.lowercased())", .meeting(id: meetingUUID, target: .tab(.summary))),

        // meeting: tab values, case-insensitive
        ("biscotti://meeting/\(meetingUUID.uuidString)?tab=summary", .meeting(id: meetingUUID, target: .tab(.summary))),
        ("biscotti://meeting/\(meetingUUID.uuidString)?tab=transcript", .meeting(id: meetingUUID, target: .tab(.transcript))),
        ("biscotti://meeting/\(meetingUUID.uuidString)?tab=notes", .meeting(id: meetingUUID, target: .tab(.notes))),
        ("biscotti://meeting/\(meetingUUID.uuidString)?tab=NOTES", .meeting(id: meetingUUID, target: .tab(.notes))),
        ("biscotti://meeting/\(meetingUUID.uuidString)?tab=Transcript", .meeting(id: meetingUUID, target: .tab(.transcript))),

        // meeting: unrecognized or empty tab falls back to Summary
        ("biscotti://meeting/\(meetingUUID.uuidString)?tab=bogus", .meeting(id: meetingUUID, target: .tab(.summary))),
        ("biscotti://meeting/\(meetingUUID.uuidString)?tab=", .meeting(id: meetingUUID, target: .tab(.summary))),

        // meeting: time implies the transcript tab
        ("biscotti://meeting/\(meetingUUID.uuidString)?time=42", .meeting(id: meetingUUID, target: .transcriptTime(42))),
        ("biscotti://meeting/\(meetingUUID.uuidString)?time=102.7", .meeting(id: meetingUUID, target: .transcriptTime(102.7))),
        ("biscotti://meeting/\(meetingUUID.uuidString)?time=0", .meeting(id: meetingUUID, target: .transcriptTime(0))),
        // Negative or oversized values parse; clamping is the consumer's job
        ("biscotti://meeting/\(meetingUUID.uuidString)?time=-5", .meeting(id: meetingUUID, target: .transcriptTime(-5))),

        // meeting: time wins when tab and time disagree
        ("biscotti://meeting/\(meetingUUID.uuidString)?tab=notes&time=42", .meeting(id: meetingUUID, target: .transcriptTime(42))),
        ("biscotti://meeting/\(meetingUUID.uuidString)?tab=notes&extra=1", .meeting(id: meetingUUID, target: .tab(.notes))),

        // search: present-but-empty query is valid; values percent-decode
        ("biscotti://search?query=hello", .search(query: "hello")),
        ("biscotti://search?query=", .search(query: "")),
        // A bare parameter (no `=`) counts as present with an empty value
        ("biscotti://search?query", .search(query: "")),
        ("biscotti://search?query=hello%20world", .search(query: "hello world")),
        ("biscotti://search?query=team%2Bstandup", .search(query: "team+standup")),
        ("biscotti://search?query=hello&other=x", .search(query: "hello")),

        // upcoming: the composite key percent-decodes
        ("biscotti://upcoming?key=evt%7Ccal%7C1700000000", .upcoming(key: "evt|cal|1700000000")),
        ("biscotti://upcoming?key=evt%2Fsub%7Ccal%7C1700000000", .upcoming(key: "evt/sub|cal|1700000000")),

        // record: optional title, trimmed; whitespace-only means absent
        ("biscotti://record", .record(title: nil)),
        ("biscotti://record?title=Standup", .record(title: "Standup")),
        ("biscotti://record?title=Q2%20Review", .record(title: "Q2 Review")),
        ("biscotti://record?title=%20%20Standup%20", .record(title: "Standup")),
        ("biscotti://record?title=%20%20", .record(title: nil)),
        // A bare parameter (no `=`) carries no value, so no title is set
        ("biscotti://record?title", .record(title: nil))
    ])
    func parsesURL(urlString: String, expected: AppLink) throws {
        let url = try #require(URL(string: urlString))
        let parsed = try #require(AppLink(url: url))
        #expect(parsed == expected)
    }

    @Test("Rejects URL", arguments: [
        // Wrong scheme
        "https://biscotti.example.com/home",
        "biscottii://home",
        "mailto:user@example.com",

        // No route, or a route that only looks like a known one
        "biscotti://",
        "biscotti://widgets",
        "biscotti://homework",

        // meeting: malformed or missing UUID, extra path segments
        "biscotti://meeting",
        "biscotti://meeting/",
        "biscotti://meeting/not-a-uuid",
        "biscotti://meeting/\(meetingUUID.uuidString)/extra",

        // meeting: a present time must parse as a number
        "biscotti://meeting/\(meetingUUID.uuidString)?time=abc",
        "biscotti://meeting/\(meetingUUID.uuidString)?time=",
        "biscotti://meeting/\(meetingUUID.uuidString)?tab=notes&time=abc",

        // meeting: `Double(_:)` accepts these, but no non-finite value is
        // a position in a recording — reject rather than seek arbitrarily
        "biscotti://meeting/\(meetingUUID.uuidString)?time=nan",
        "biscotti://meeting/\(meetingUUID.uuidString)?time=inf",
        "biscotti://meeting/\(meetingUUID.uuidString)?time=-inf",
        "biscotti://meeting/\(meetingUUID.uuidString)?time=infinity",
        "biscotti://meeting/\(meetingUUID.uuidString)?time=1e999",

        // search: query parameter wholly absent
        "biscotti://search",

        // upcoming: key absent or empty
        "biscotti://upcoming",
        "biscotti://upcoming?key="
    ])
    func rejectsURL(urlString: String) throws {
        let url = try #require(URL(string: urlString))
        #expect(AppLink(url: url) == nil)
    }
}
