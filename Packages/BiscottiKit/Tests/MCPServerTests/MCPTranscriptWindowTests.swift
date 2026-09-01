import DataStore
import Foundation
import Testing
@testable import MCPServer

/// `biscotti_get_transcript` window params (`start_seconds`/`end_seconds`)
/// end to end over the real listener (functional spec §5.3): the half-open
/// `[start, end)` overlap window, absolute timestamps, empty windows, and
/// invalid bounds.
@Suite("MCP get_transcript window params")
struct MCPTranscriptWindowTests {
    @Test("windows filter by [start, end) overlap; timestamps stay absolute")
    func windowedRetrieval() async throws {
        let store = try DataStore(storage: .inMemory)
        let meetingID = try await seedWindowedMeeting(in: store)

        try await MCPServerFixture.withRunningServer(store: store) { fixture in
            func transcript(_ arguments: [String: Any]) async throws -> [String: Any] {
                try await Self.transcript(port: fixture.port, arguments: arguments)
            }

            let fullText = "[0:04] Speaker 0\nFirst\n\n[0:10] Speaker 1\nSecond\n\n[0:20] Speaker 0\nThird"

            // No params: today's full output.
            let full = try await transcript(["id": meetingID.uuidString])
            #expect(full["text"] as? String == fullText)
            #expect(full["word_count"] as? Int == 3)

            // Sub-window [9, 20): only the 10–15 segment; a segment ending
            // exactly at the window start is out (start inclusive), and one
            // starting exactly at the window end is out (end exclusive).
            let sub = try await transcript([
                "id": meetingID.uuidString, "start_seconds": 9, "end_seconds": 20
            ])
            #expect(sub["text"] as? String == "[0:10] Speaker 1\nSecond")
            #expect(sub["word_count"] as? Int == 1)

            // Start inclusive: [10, 20) still catches the 10–15 segment.
            let inclusive = try await transcript([
                "id": meetingID.uuidString, "start_seconds": 10, "end_seconds": 20
            ])
            #expect(inclusive["text"] as? String == "[0:10] Speaker 1\nSecond")

            // Bounds are independently optional: start alone, end alone.
            let startAlone = try await transcript([
                "id": meetingID.uuidString, "start_seconds": 15
            ])
            #expect(startAlone["text"] as? String == "[0:20] Speaker 0\nThird")
            let endAlone = try await transcript([
                "id": meetingID.uuidString, "end_seconds": 10
            ])
            #expect(endAlone["text"] as? String == "[0:04] Speaker 0\nFirst")
        }
    }

    @Test("windows that match nothing return empty, not an error")
    func emptyWindows() async throws {
        let store = try DataStore(storage: .inMemory)
        let meetingID = try await seedWindowedMeeting(in: store)

        try await MCPServerFixture.withRunningServer(store: store) { fixture in
            func transcript(_ arguments: [String: Any]) async throws -> [String: Any] {
                try await Self.transcript(port: fixture.port, arguments: arguments)
            }

            let id: [String: Any] = ["id": meetingID.uuidString]

            // Past the end and before the start.
            for window in [
                ["start_seconds": 1000, "end_seconds": 2000],
                ["start_seconds": -50, "end_seconds": -10]
            ] as [[String: Any]] {
                let empty = try await transcript(id.merging(window) { _, new in new })
                #expect(empty["text"] as? String == "")
                #expect(empty["word_count"] as? Int == 0)
                #expect(empty["character_count"] as? Int == 0)
            }

            // start ≥ end (equal and inverted): an empty window. The points
            // sit *inside* the [4,9) segment on purpose — interval math
            // alone would keep a straddling segment, so these prove the
            // early empty-window exit.
            for window in [
                ["start_seconds": 6, "end_seconds": 6],
                ["start_seconds": 8, "end_seconds": 5]
            ] as [[String: Any]] {
                let empty = try await transcript(id.merging(window) { _, new in new })
                #expect(empty["text"] as? String == "")
                #expect(empty["word_count"] as? Int == 0)
            }

            // A non-numeric bound is invalid params.
            let badType = try await JSONRPCClient.post(
                port: fixture.port,
                method: "tools/call",
                params: [
                    "name": "biscotti_get_transcript",
                    "arguments": [
                        "id": meetingID.uuidString, "start_seconds": "soon"
                    ] as [String: Any]
                ]
            )
            let error = try #require(badType.body["error"] as? [String: Any])
            #expect(error["code"] as? Int == -32602)
        }
    }

    /// Calls `biscotti_get_transcript` over the wire and returns its
    /// `structuredContent`, asserting the call succeeded along the way.
    private static func transcript(
        port: Int, arguments: [String: Any]
    ) async throws -> [String: Any] {
        let response = try await JSONRPCClient.post(
            port: port,
            method: "tools/call",
            params: [
                "name": "biscotti_get_transcript",
                "arguments": arguments
            ] as [String: Any]
        )
        #expect(response.status == 200)
        let result = try #require(response.body["result"] as? [String: Any])
        #expect(result["isError"] == nil)
        return try #require(result["structuredContent"] as? [String: Any])
    }

    /// Segments [4,9), [10,15), [20,25) — two speakers, non-contiguous, so
    /// window boundaries are exact and turn timestamps stay distinct.
    private func seedWindowedMeeting(in store: DataStore) async throws -> UUID {
        let meetingID = try await store.createMeeting(
            title: "Weekly sync",
            start: ToolDateFormatting.parse("2026-08-27T17:00:00Z")
        )
        try await ToolTestSupport.addTranscript(
            to: store,
            meetingID: meetingID,
            segments: [
                ToolTestSupport.makeSegment("First", speaker: 0, label: "Speaker 0", start: 4),
                ToolTestSupport.makeSegment("Second", speaker: 1, label: "Speaker 1", start: 10),
                ToolTestSupport.makeSegment("Third", speaker: 0, label: "Speaker 0", start: 20)
            ]
        )
        return meetingID
    }
}
