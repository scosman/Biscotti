import Calendar
import Foundation
import Testing
@testable import GraphCalendar

/// Calendar mapping, the account's "is me" rule and the mapper's lookup
/// tables (functional spec §4.1, §4.2, §4.4).
@Suite("Graph calendars, account and lookup tables")
struct GraphCalendarMappingTests {
    @Test("calendars: shared ones carry their owner; colors are normalized")
    func calendarInfo() throws {
        let page = try JSONDecoder().decode(GraphPage<Graph.Calendar>.self, from: Fixture.data("calendars"))
        let infos = page.value.map(GraphEventMapper(account: TestAccount.jane).calendarInfo)

        #expect(infos.map(\.id) == ["cal-own", "cal-project", "cal-shared", "cal-partner"])
        #expect(infos.map(\.title) == ["Calendar", "Project X", "Calendar (Pat Smith)", "Calendar (lee@partner.example)"])
        #expect(infos.map(\.colorHex) == ["#808080", "#A3C4FF", "#FFB878", "#808080"])
        #expect(infos.allSatisfy { $0.sourceTitle == "Microsoft 365 (jane@synderys.com)" })
    }

    @Test("hex color normalization", arguments: [
        ("#a3c4ff", "#A3C4FF"), ("a3c4ff", "#A3C4FF"), (" #0F0f0F ", "#0F0F0F"),
        ("", "#808080"), ("blue", "#808080"), ("#12345", "#808080"), (nil, "#808080")
    ] as [(String?, String)])
    func hexNormalization(value: String?, expected: String) {
        #expect(GraphEventMapper.normalizedHex(value) == expected)
    }

    @Test("participant status mapping", arguments: [
        ("accepted", "accepted"), ("organizer", "accepted"), ("tentativelyAccepted", "tentative"),
        ("declined", "declined"), ("notResponded", "pending"), ("none", "unknown"), (nil, "unknown")
    ] as [(String?, String)])
    func participantStatus(response: String?, expected: String) {
        #expect(GraphEventMapper.participantStatus(response) == expected)
    }

    @Test("attendee type → role and participant type", arguments: [
        ("required", ("required", "person")), ("optional", ("optional", "person")),
        ("resource", ("nonParticipant", "resource")), ("other", ("unknown", "unknown")), (nil, ("unknown", "unknown"))
    ] as [(String?, (role: String, type: String))])
    func attendeeType(graphType: String?, expected: (role: String, type: String)) {
        let mapped = GraphEventMapper.roleAndType(graphType)
        #expect(mapped.role == expected.role)
        #expect(mapped.type == expected.type)
    }

    @Test("current-user matching uses mail and UPN, case-insensitively")
    func currentUserMatching() {
        let account = TestAccount.jane
        #expect(account.isCurrentUser(address: "JANE@SYNDERYS.COM"))
        #expect(account.isCurrentUser(address: " jane.doe@synderys.com "))
        #expect(!account.isCurrentUser(address: "pat@synderys.com"))
        #expect(!account.isCurrentUser(address: ""))
        #expect(!account.isCurrentUser(address: nil))

        let noMail = GraphAccount(userPrincipalName: "jane@synderys.com", mail: nil)
        #expect(noMail.isCurrentUser(address: "jane@synderys.com"))
        #expect(!noMail.isCurrentUser(address: "jane.doe@synderys.com"))
    }
}
