import DataStore
import Foundation
import Testing
import Transcription
@testable import MCPServer

/// `tools/call` end to end over the real listener on an ephemeral port,
/// against a seeded store (architecture §10 "Transport / HTTP" tool leg).
@Suite("MCP tools/call end to end")
struct MCPToolRoundTripTests {
    @Test("initialize, list, and query over the wire")
    func fullToolFlow() async throws {
        let store = try DataStore(storage: .inMemory)
        let meetingID = try await seedMeeting(in: store)

        try await MCPServerFixture.withRunningServer(store: store) { fixture in
            let initialize = try await JSONRPCClient.post(
                port: fixture.port,
                method: "initialize",
                params: [
                    "protocolVersion": "2025-11-25",
                    "capabilities": [:] as [String: Any],
                    "clientInfo": ["name": "MCPServerTests", "version": "0"]
                ]
            )
            #expect(initialize.status == 200)

            let listTools = try await JSONRPCClient.post(port: fixture.port, method: "tools/list")
            let tools = try #require(
                (listTools.body["result"] as? [String: Any])?["tools"] as? [[String: Any]]
            )
            #expect(tools.count == 3)

            let query = try await JSONRPCClient.post(
                port: fixture.port,
                method: "tools/call",
                params: [
                    "name": "biscotti_query_meetings",
                    "arguments": ["after": "2000-01-01", "limit": 10] as [String: Any]
                ]
            )
            #expect(query.status == 200)
            let queryResult = try #require(query.body["result"] as? [String: Any])
            #expect(queryResult["isError"] == nil)
            let queryStructured = try #require(queryResult["structuredContent"] as? [String: Any])
            let results = try #require(queryStructured["results"] as? [[String: Any]])
            #expect(results.count == 1)
            #expect(results[0]["id"] as? String == meetingID.uuidString)
        }
    }

    @Test("get_meeting and get_transcript over the wire")
    func detailAndTranscriptOverWire() async throws {
        let store = try DataStore(storage: .inMemory)
        let meetingID = try await seedMeeting(in: store)

        try await MCPServerFixture.withRunningServer(store: store) { fixture in
            let detail = try await JSONRPCClient.post(
                port: fixture.port,
                method: "tools/call",
                params: [
                    "name": "biscotti_get_meeting",
                    "arguments": ["id": meetingID.uuidString] as [String: Any]
                ]
            )
            #expect(detail.status == 200)
            let detailStructured = try #require(
                (detail.body["result"] as? [String: Any])?["structuredContent"] as? [String: Any]
            )
            let transcriptStats = try #require(detailStructured["transcript"] as? [String: Any])
            #expect(transcriptStats["available"] as? Bool == true)
            #expect(transcriptStats["segment_count"] as? Int == 1)

            let transcript = try await JSONRPCClient.post(
                port: fixture.port,
                method: "tools/call",
                params: [
                    "name": "biscotti_get_transcript",
                    "arguments": ["id": meetingID.uuidString] as [String: Any]
                ]
            )
            #expect(transcript.status == 200)
            let transcriptStructured = try #require(
                (transcript.body["result"] as? [String: Any])?["structuredContent"] as? [String: Any]
            )
            #expect((transcriptStructured["text"] as? String)?.contains("[00:04]") == true)
        }
    }

    @Test("unknown tool name is a JSON-RPC method-not-found error")
    func unknownToolOverWire() async throws {
        try await MCPServerFixture.withRunningServer { fixture in
            let response = try await JSONRPCClient.post(
                port: fixture.port,
                method: "tools/call",
                params: ["name": "biscotti_nonsense", "arguments": [:] as [String: Any]]
            )
            let error = try #require(response.body["error"] as? [String: Any])
            #expect(error["code"] as? Int == -32601)
        }
    }

    @Test("invalid tool arguments are a JSON-RPC invalid-params error")
    func invalidParamsOverWire() async throws {
        try await MCPServerFixture.withRunningServer { fixture in
            // An unparseable date is the invalid-params case (`limit` alone
            // is now legal — "newest N").
            let response = try await JSONRPCClient.post(
                port: fixture.port,
                method: "tools/call",
                params: [
                    "name": "biscotti_query_meetings",
                    "arguments": ["after": "not-a-date"] as [String: Any]
                ]
            )
            let error = try #require(response.body["error"] as? [String: Any])
            #expect(error["code"] as? Int == -32602)
        }
    }

    @Test("unknown meeting id is a tool error result, not a protocol error")
    func unknownIDOverWire() async throws {
        try await MCPServerFixture.withRunningServer { fixture in
            let response = try await JSONRPCClient.post(
                port: fixture.port,
                method: "tools/call",
                params: [
                    "name": "biscotti_get_meeting",
                    "arguments": ["id": UUID().uuidString] as [String: Any]
                ]
            )
            #expect(response.status == 200)
            let result = try #require(response.body["result"] as? [String: Any])
            #expect(result["isError"] as? Bool == true)
            let content = try #require(result["content"] as? [[String: Any]])
            #expect(content.first?["text"] as? String == "No meeting with that id.")
        }
    }

    private func seedMeeting(in store: DataStore) async throws -> UUID {
        let meetingID = try await store.createMeeting(
            title: "Weekly sync",
            start: ToolDateFormatting.parse("2026-08-27T17:00:00Z")
        )
        let result = TranscriptResult(
            transcriptionMethodId: "v1",
            language: "en",
            speakerCount: 2,
            segments: [
                TranscriptSegment(
                    speakerID: 0, speakerLabel: "Speaker 0",
                    startTime: 4, endTime: 9, text: "Let's start with the roadmap.",
                    confidence: 0.9, noSpeechProbability: 0.1, words: nil
                )
            ],
            speakerEmbeddings: [:],
            processingDuration: 1
        )
        let transcriptID = try await store.addTranscript(
            result, vocabularyUsed: [], mappedEventIdentifier: nil, to: meetingID
        )
        try await store.setPreferredTranscript(transcriptID, for: meetingID)
        return meetingID
    }
}
