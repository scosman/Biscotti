import AppLinks
import Foundation
import Testing

/// Fixed UUID so failures are reproducible across runs.
private let meetingUUID = UUID(uuidString: "6B8F9C2A-1D3E-4F5A-9B2C-8E7D1A0F3B45")
    ?? UUID()

@Suite("AppLink — Building")
struct AppLinkBuildingTests {
    @Test("Round-trips through parse", arguments: [
        AppLink.home,
        .meetings,
        .settings,

        // Every meeting target, including the default-tab no-query form
        .meeting(id: meetingUUID, target: .tab(.summary)),
        .meeting(id: meetingUUID, target: .tab(.transcript)),
        .meeting(id: meetingUUID, target: .tab(.notes)),
        .meeting(id: meetingUUID, target: .transcriptTime(0)),
        .meeting(id: meetingUUID, target: .transcriptTime(42)),
        .meeting(id: meetingUUID, target: .transcriptTime(102.7)),
        .meeting(id: meetingUUID, target: .transcriptTime(-5)),

        // Search values survive percent-encoding, including the empty query
        .search(query: "hello"),
        .search(query: ""),
        .search(query: "hello world"),
        .search(query: "team+standup & such?"),

        // Composite keys contain '|' and '/'
        .upcoming(key: "evt|cal|1700000000"),
        .upcoming(key: "evt/sub|cal|1700000000"),

        .record(title: nil),
        .record(title: "Standup"),
        .record(title: "Q2 Review")
    ])
    func roundTripsThroughParse(link: AppLink) throws {
        let parsed = try #require(AppLink(url: link.url))
        #expect(parsed == link)
    }

    @Test("Builds canonical URL", arguments: [
        (AppLink.home, "biscotti://home"),
        (.meetings, "biscotti://meetings"),
        (.settings, "biscotti://settings"),

        // The default tab emits no query — the shape MCP and Copy Meeting Link emit
        (.meeting(id: meetingUUID, target: .tab(.summary)), "biscotti://meeting/\(meetingUUID.uuidString)"),
        (.meeting(id: meetingUUID, target: .tab(.notes)), "biscotti://meeting/\(meetingUUID.uuidString)?tab=notes"),
        // Whole-number times render without a fractional part; others keep
        // Double's shortest round-tripping description
        (.meeting(id: meetingUUID, target: .transcriptTime(42)), "biscotti://meeting/\(meetingUUID.uuidString)?time=42"),
        (.meeting(id: meetingUUID, target: .transcriptTime(102.7)), "biscotti://meeting/\(meetingUUID.uuidString)?time=102.7"),

        (.search(query: "hello world"), "biscotti://search?query=hello%20world"),
        (.upcoming(key: "evt|cal|1700000000"), "biscotti://upcoming?key=evt%7Ccal%7C1700000000"),

        (.record(title: nil), "biscotti://record"),
        (.record(title: "Q2 Review"), "biscotti://record?title=Q2%20Review")
    ])
    func buildsCanonicalURL(link: AppLink, expected: String) {
        #expect(link.url.absoluteString == expected)
    }
}
