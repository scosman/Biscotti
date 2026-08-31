import DataStore
import Foundation
import MCP
import Testing
@testable import MCPServer

/// `biscotti_query_meetings` against an in-memory `DataStore`, no sockets
/// (architecture §10 "Tool logic"). Detail/transcript tools live in
/// `MeetingToolDetailTests`.
@Suite("biscotti_query_meetings")
struct MeetingToolProviderTests {
    // MARK: - Validation

    @Test("no filter lists the most recent meetings first")
    func queryNoFilterListsNewestFirst() async throws {
        let (provider, store) = try ToolTestSupport.makeProvider()
        let ids = try await ToolTestSupport.seedThreeDatedMeetings(store)

        // No arguments and an empty object mean the same thing: the
        // newest-first list, not an error.
        for arguments: [String: Value]? in [nil, [:]] {
            let result = try await provider.call(
                name: "biscotti_query_meetings",
                arguments: arguments
            )
            #expect(result.isError != true)

            let object = try ToolTestSupport.jsonObject(from: result)
            #expect(try ToolTestSupport.idList(result) == [
                ids[2].uuidString, ids[1].uuidString, ids[0].uuidString
            ])
            #expect(object["results_truncated"] as? Bool == false)
            let results = try #require(object["results"] as? [[String: Any]])
            for item in results {
                #expect(item.keys.contains("query_snippet") == false)
            }
        }
    }

    @Test("limit alone returns the newest N")
    func queryLimitAloneReturnsNewestN() async throws {
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

    @Test("empty query string is invalid params")
    func queryEmptyStringIsInvalid() async throws {
        let (provider, _) = try ToolTestSupport.makeProvider()
        try await ToolTestSupport.expectInvalidParams(
            provider, name: "biscotti_query_meetings", arguments: ["query": .string("   ")]
        )
    }

    @Test("unparseable date is invalid params")
    func queryBadDateIsInvalid() async throws {
        let (provider, _) = try ToolTestSupport.makeProvider()
        try await ToolTestSupport.expectInvalidParams(
            provider,
            name: "biscotti_query_meetings",
            arguments: ["after": .string("not-a-date")]
        )
    }

    @Test("after later than before is invalid params")
    func queryAfterBeforeSwappedIsInvalid() async throws {
        let (provider, _) = try ToolTestSupport.makeProvider()
        try await ToolTestSupport.expectInvalidParams(
            provider,
            name: "biscotti_query_meetings",
            arguments: [
                "after": .string("2026-09-01T00:00:00Z"),
                "before": .string("2026-08-01T00:00:00Z")
            ]
        )
    }

    @Test("limit outside 1...50 is invalid params")
    func queryLimitOutOfRangeIsInvalid() async throws {
        let (provider, _) = try ToolTestSupport.makeProvider()
        for limit in [Value.int(0), .int(-1), .int(51), .int(500)] {
            try await ToolTestSupport.expectInvalidParams(
                provider,
                name: "biscotti_query_meetings",
                arguments: ["after": .string("2026-01-01"), "limit": limit]
            )
        }
    }

    @Test("non-integer limit is invalid params")
    func queryLimitDoubleIsInvalid() async throws {
        let (provider, _) = try ToolTestSupport.makeProvider()
        try await ToolTestSupport.expectInvalidParams(
            provider,
            name: "biscotti_query_meetings",
            arguments: ["after": .string("2026-01-01"), "limit": .double(5.5)]
        )
    }

    // MARK: - Behavior

    @Test("date-only after returns newest-first and accepts a bare date")
    func queryDateOnlyNewestFirst() async throws {
        let (provider, store) = try ToolTestSupport.makeProvider()
        let ids = try await ToolTestSupport.seedThreeDatedMeetings(store)

        let result = try await provider.call(
            name: "biscotti_query_meetings",
            arguments: ["after": .string("2026-07-01")]
        )
        #expect(result.isError != true)

        let object = try ToolTestSupport.jsonObject(from: result)
        let results = try #require(object["results"] as? [[String: Any]])
        // July 1 local midnight is after the June meeting and before the July
        // meeting in every timezone, so the range is TZ-stable.
        #expect(results.count == 2)
        #expect(results[0]["id"] as? String == ids[2].uuidString)
        #expect(results[1]["id"] as? String == ids[1].uuidString)
        #expect(object["results_truncated"] as? Bool == false)
        for item in results {
            #expect(item.keys.contains("query_snippet") == false)
        }
    }

    @Test("after and before bounds are inclusive")
    func queryInclusiveBounds() async throws {
        let (provider, store) = try ToolTestSupport.makeProvider()
        let ids = try await ToolTestSupport.seedThreeDatedMeetings(store)
        let middle = try ToolDateFormatting.format(
            #require(ToolDateFormatting.parse("2026-07-15T12:00:00Z"))
        )

        let afterResult = try await provider.call(
            name: "biscotti_query_meetings",
            arguments: ["after": .string(middle)]
        )
        #expect(try ToolTestSupport.idList(afterResult) == [ids[2].uuidString, ids[1].uuidString])

        let beforeResult = try await provider.call(
            name: "biscotti_query_meetings",
            arguments: ["before": .string(middle)]
        )
        #expect(try ToolTestSupport.idList(beforeResult) == [ids[1].uuidString, ids[0].uuidString])
    }

    @Test("title matches rank ahead of transcript matches")
    func queryRelevanceOrder() async throws {
        let (provider, store) = try ToolTestSupport.makeProvider()
        let titleMatchA = try await store.createMeeting(
            title: "Roadmap review", start: ToolDateFormatting.parse("2026-08-01T09:00:00Z")
        )
        let titleMatchB = try await store.createMeeting(
            title: "Roadmap follow-up", start: ToolDateFormatting.parse("2026-08-02T09:00:00Z")
        )
        let bodyMatch = try await store.createMeeting(
            title: "Design sync", start: ToolDateFormatting.parse("2026-08-03T09:00:00Z")
        )
        try await ToolTestSupport.addTranscript(
            to: store,
            meetingID: bodyMatch,
            segments: [
                ToolTestSupport.makeSegment(
                    "we discussed the roadmap and the deck", speaker: 0, label: "Speaker 0", start: 0
                )
            ]
        )

        let result = try await provider.call(
            name: "biscotti_query_meetings",
            arguments: ["query": .string("roadmap")]
        )
        let ids = try ToolTestSupport.idList(result)
        #expect(ids.count == 3)
        #expect(ids.last == bodyMatch.uuidString)
        #expect(Set(ids.prefix(2)) == Set([titleMatchA.uuidString, titleMatchB.uuidString]))

        // Snippets appear on the query path.
        let object = try ToolTestSupport.jsonObject(from: result)
        let results = try #require(object["results"] as? [[String: Any]])
        for item in results {
            #expect((item["query_snippet"] as? String)?.isEmpty == false)
        }
    }

    @Test("query stacks with a date range")
    func queryWithDateRange() async throws {
        let (provider, store) = try ToolTestSupport.makeProvider()
        let inRange = try await store.createMeeting(
            title: "Roadmap review", start: ToolDateFormatting.parse("2026-08-01T09:00:00Z")
        )
        let outOfRange = try await store.createMeeting(
            title: "Design sync", start: ToolDateFormatting.parse("2026-08-20T09:00:00Z")
        )
        try await ToolTestSupport.addTranscript(
            to: store,
            meetingID: outOfRange,
            segments: [
                ToolTestSupport.makeSegment(
                    "we discussed the roadmap", speaker: 0, label: "Speaker 0", start: 0
                )
            ]
        )

        // Both meetings match "roadmap"; the range keeps only the August 1 one.
        // This is also the bounded-pool-500 path: ranked candidates are drawn
        // from the FTS index before the date filter is applied.
        let result = try await provider.call(
            name: "biscotti_query_meetings",
            arguments: [
                "query": .string("roadmap"),
                "before": .string("2026-08-10T00:00:00Z")
            ]
        )
        #expect(try ToolTestSupport.idList(result) == [inRange.uuidString])

        // The excluded match still surfaces without the range.
        let unfiltered = try await provider.call(
            name: "biscotti_query_meetings",
            arguments: ["query": .string("roadmap")]
        )
        #expect(try Set(ToolTestSupport.idList(unfiltered)) == Set([
            inRange.uuidString, outOfRange.uuidString
        ]))
    }

    @Test("results_truncated is true at exactly the limit, false below")
    func queryTruncationFlag() async throws {
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

    @Test("no matches is an empty result, not an error")
    func queryNoMatches() async throws {
        let (provider, store) = try ToolTestSupport.makeProvider()
        try await ToolTestSupport.seedThreeDatedMeetings(store)

        let result = try await provider.call(
            name: "biscotti_query_meetings",
            arguments: ["query": .string("xyzzynothingmatches")]
        )
        #expect(result.isError != true)
        let object = try ToolTestSupport.jsonObject(from: result)
        #expect((object["results"] as? [Any])?.isEmpty == true)
        #expect(object["results_truncated"] as? Bool == false)
    }

    @Test("success carries the same object as text and structuredContent")
    func textAndStructuredContentAgree() async throws {
        let (provider, store) = try ToolTestSupport.makeProvider()
        try await ToolTestSupport.seedThreeDatedMeetings(store)

        let result = try await provider.call(
            name: "biscotti_query_meetings",
            arguments: ["after": .string("2026-01-01")]
        )
        guard case let .text(json, _, _)? = result.content.first else {
            Issue.record("Expected text content")
            return
        }
        let textObject = try #require(
            JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any]
        )
        let structuredObject = try ToolTestSupport.jsonObject(from: result)
        let textJSON = try JSONSerialization.data(withJSONObject: textObject, options: [.sortedKeys])
        let structuredJSON = try JSONSerialization.data(
            withJSONObject: structuredObject, options: [.sortedKeys]
        )
        #expect(textJSON == structuredJSON)
    }
}
