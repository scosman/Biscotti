import DataStore
import Foundation
import MCP
import Testing
import Transcription
@testable import MCPServer

// Shared fixtures and helpers for the tool-logic suites.

enum ToolTestSupport {
    static func makeProvider() throws -> (provider: MeetingToolProvider, store: DataStore) {
        let store = try DataStore(storage: .inMemory)
        return (MeetingToolProvider(store: store), store)
    }

    static func jsonObject(from result: CallTool.Result) throws -> [String: Any] {
        let value = try #require(result.structuredContent)
        let data = try JSONEncoder().encode(value)
        return try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    static func expectInvalidParams(
        _ provider: MeetingToolProvider,
        name: String,
        arguments: [String: Value]?
    ) async throws {
        do {
            let result = try await provider.call(name: name, arguments: arguments)
            Issue.record("Expected invalidParams, got a result: \(result)")
        } catch let error as MCPError {
            #expect(error.code == -32602)
        }
    }

    static func errorText(_ result: CallTool.Result) throws -> String {
        #expect(result.isError == true)
        guard case let .text(text, _, _)? = result.content.first else {
            Issue.record("Expected text content")
            return ""
        }
        return text
    }

    static func makeSegment(
        _ text: String, speaker: Int?, label: String, start: TimeInterval
    ) -> TranscriptSegment {
        TranscriptSegment(
            speakerID: speaker,
            speakerLabel: label,
            startTime: start,
            endTime: start + 5,
            text: text,
            confidence: 0.9,
            noSpeechProbability: 0.1,
            words: nil
        )
    }

    @discardableResult
    static func addTranscript(
        to store: DataStore, meetingID: UUID, segments: [TranscriptSegment], speakerCount: Int = 2
    ) async throws -> UUID {
        let result = TranscriptResult(
            transcriptionMethodId: "v1",
            language: "en",
            speakerCount: speakerCount,
            segments: segments,
            speakerEmbeddings: [:],
            processingDuration: 1
        )
        let transcriptID = try await store.addTranscript(
            result, vocabularyUsed: [], mappedEventIdentifier: nil, to: meetingID
        )
        try await store.setPreferredTranscript(transcriptID, for: meetingID)
        return transcriptID
    }

    /// Three meetings on 2026-06-15, 2026-07-15, 2026-08-15, all at midday
    /// UTC so bare-date filters are timezone-stable. Returns [oldest, middle, newest].
    static func seedThreeDatedMeetings(_ store: DataStore) async throws -> [UUID] {
        let dates = try ["2026-06-15T12:00:00Z", "2026-07-15T12:00:00Z", "2026-08-15T12:00:00Z"]
            .map { try #require(ToolDateFormatting.parse($0)) }
        var ids: [UUID] = []
        for (idx, date) in dates.enumerated() {
            try await ids.append(store.createMeeting(title: "Meeting \(idx)", start: date))
        }
        return ids
    }

    static func idList(_ result: CallTool.Result) throws -> [String] {
        let object = try jsonObject(from: result)
        return try #require(object["results"] as? [[String: Any]])
            .compactMap { $0["id"] as? String }
    }
}
