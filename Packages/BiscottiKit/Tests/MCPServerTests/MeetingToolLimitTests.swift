import DataStore
import Foundation
import MCP
import Testing
@testable import MCPServer

/// The `limit` parameter of `biscotti_query_meetings` (cap 250, default 20)
/// and the `results_truncated` flag it drives, against an in-memory
/// `DataStore`, no sockets.
@Suite("biscotti_query_meetings limit")
struct MeetingToolLimitTests {
    @Test("limit alone returns the newest N")
    func limitAloneReturnsNewestN() async throws {
        let (provider, store) = try ToolTestSupport.makeProvider()
        let ids = try await ToolTestSupport.seedThreeDatedMeetings(store)

        let result = try await provider.call(
            name: "biscotti_query_meetings",
            arguments: ["limit": .int(2)]
        )
        #expect(result.isError != true)
        #expect(try ToolTestSupport.idList(result) == [
            ids[2].uuidString, ids[1].uuidString
        ])
        #expect(try ToolTestSupport.jsonObject(from: result)["results_truncated"] as? Bool == true)
    }

    @Test("limit cap is 250 and the default stays 20")
    func limitCapAndDefault() async throws {
        let (provider, store) = try ToolTestSupport.makeProvider()
        let start = try #require(ToolDateFormatting.parse("2026-08-01T12:00:00Z"))
        for idx in 0 ..< 60 {
            _ = try await store.createMeeting(title: "Meeting \(idx)", start: start)
        }

        // No limit: the newest 20 (the default), flagged truncated.
        let defaulted = try await provider.call(name: "biscotti_query_meetings", arguments: [:])
        #expect(try ToolTestSupport.idList(defaulted).count == 20)
        #expect(
            try ToolTestSupport.jsonObject(from: defaulted)["results_truncated"] as? Bool == true
        )

        // 250 is accepted: all 60 fit, nothing truncated.
        let capped = try await provider.call(
            name: "biscotti_query_meetings", arguments: ["limit": .int(250)]
        )
        #expect(try ToolTestSupport.idList(capped).count == 60)
        #expect(try ToolTestSupport.jsonObject(from: capped)["results_truncated"] as? Bool == false)
    }

    @Test("limit outside 1...250 is invalid params")
    func limitOutOfRangeIsInvalid() async throws {
        let (provider, _) = try ToolTestSupport.makeProvider()
        for limit in [Value.int(0), .int(-1), .int(251), .int(500)] {
            try await ToolTestSupport.expectInvalidParams(
                provider,
                name: "biscotti_query_meetings",
                arguments: ["after": .string("2026-01-01"), "limit": limit]
            )
        }
    }

    @Test("non-integer limit is invalid params")
    func limitDoubleIsInvalid() async throws {
        let (provider, _) = try ToolTestSupport.makeProvider()
        try await ToolTestSupport.expectInvalidParams(
            provider,
            name: "biscotti_query_meetings",
            arguments: ["after": .string("2026-01-01"), "limit": .double(5.5)]
        )
    }

    @Test("results_truncated is true at exactly the limit, false below")
    func truncationFlag() async throws {
        let (provider, store) = try ToolTestSupport.makeProvider()
        try await ToolTestSupport.seedThreeDatedMeetings(store)

        let atLimit = try await provider.call(
            name: "biscotti_query_meetings",
            arguments: ["after": .string("2026-01-01"), "limit": .int(3)]
        )
        #expect(try ToolTestSupport.jsonObject(from: atLimit)["results_truncated"] as? Bool == true)

        let underLimit = try await provider.call(
            name: "biscotti_query_meetings",
            arguments: ["after": .string("2026-07-01"), "limit": .int(3)]
        )
        #expect(
            try ToolTestSupport.jsonObject(from: underLimit)["results_truncated"] as? Bool == false
        )
    }
}
