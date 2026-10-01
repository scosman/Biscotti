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

    @Test("a saturated candidate pool marks results_truncated even below the limit")
    func poolExhaustionMarksTruncated() async throws {
        let (provider, store) = try ToolTestSupport.makeProvider()
        // One more matching meeting than the ranked pool holds, one per
        // day from 2026-01-01: a one-month window then matches ~30 of them
        // — far below the limit — while the pool is exhausted, so more
        // matches may exist outside it (architecture §6.1).
        let start = try #require(ToolDateFormatting.parse("2026-01-01T12:00:00Z"))
        for idx in 0 ... MCPServerConfiguration.searchCandidatePool {
            _ = try await store.createMeeting(
                title: "Standup \(idx)",
                start: start.addingTimeInterval(Double(idx) * 60 * 60 * 24)
            )
        }

        let narrowed = try await provider.call(
            name: "biscotti_query_meetings",
            arguments: [
                "query": .string("standup"),
                "after": .string("2026-06-01"),
                "before": .string("2026-07-01"),
                "limit": .int(250)
            ]
        )
        let object = try ToolTestSupport.jsonObject(from: narrowed)
        let results = try #require(object["results"] as? [[String: Any]])
        #expect(!results.isEmpty)
        #expect(results.count < 250)
        #expect(object["results_truncated"] as? Bool == true)
    }

    @Test("a sub-pool query result below the limit is not truncated")
    func subPoolQueryBelowLimitNotTruncated() async throws {
        let (provider, store) = try ToolTestSupport.makeProvider()
        try await ToolTestSupport.seedThreeDatedMeetings(store)

        // The pool (3 FTS hits) is far from saturated and the window
        // leaves 2 results under the limit: neither truncation condition
        // holds.
        let result = try await provider.call(
            name: "biscotti_query_meetings",
            arguments: [
                "query": .string("meeting"),
                "after": .string("2026-07-01"),
                "limit": .int(20)
            ]
        )
        #expect(try ToolTestSupport.idList(result).count == 2)
        #expect(try ToolTestSupport.jsonObject(from: result)["results_truncated"] as? Bool == false)
    }
}
