import DataStore
import Foundation
import Testing
@testable import MCPServer

/// `biscotti_get_meeting`'s `audio_files` behavior: stored paths survive
/// file deletion, paired with `present` (functional spec §5.2).
@Suite("biscotti_get_meeting audio_files")
struct MeetingToolAudioTests {
    @Test("reports stored paths with present false when audio files are gone")
    func getMeetingDeletedAudio() async throws {
        let (provider, store) = try ToolTestSupport.makeProvider()
        let meetingID = try await store.createMeeting(title: "Cleaned up")
        try await store.attachAudio(
            [AudioFileRef(role: .mic, path: "/gone/mic.aac", byteSize: 0, isPresent: false),
             AudioFileRef(role: .system, path: "/gone/system.aac", byteSize: 0, isPresent: false)],
            to: meetingID
        )

        let result = try await provider.call(
            name: "biscotti_get_meeting",
            arguments: ["id": .string(meetingID.uuidString)]
        )
        let audio = try #require(
            try ToolTestSupport.jsonObject(from: result)["audio_files"] as? [String: Any]
        )
        #expect(audio["present"] as? Bool == false)
        #expect(audio["microphone"] as? String == "/gone/mic.aac")
        #expect(audio["system"] as? String == "/gone/system.aac")
    }

    @Test("reports each file's own state when only one survives")
    func getMeetingPartiallyDeletedAudio() async throws {
        let (provider, store) = try ToolTestSupport.makeProvider()
        let meetingID = try await store.createMeeting(title: "Half cleaned")
        try await store.attachAudio(
            [AudioFileRef(role: .mic, path: "/kept/mic.aac", byteSize: 100, isPresent: true),
             AudioFileRef(role: .system, path: "/gone/system.aac", byteSize: 0, isPresent: false)],
            to: meetingID
        )

        let result = try await provider.call(
            name: "biscotti_get_meeting",
            arguments: ["id": .string(meetingID.uuidString)]
        )
        let audio = try #require(
            try ToolTestSupport.jsonObject(from: result)["audio_files"] as? [String: Any]
        )
        #expect(audio["present"] as? Bool == true)
        #expect(audio["microphone"] as? String == "/kept/mic.aac")
        #expect(audio["system"] as? String == "/gone/system.aac")
    }

    @Test("omits path keys when the meeting has no refs at all")
    func getMeetingNoRefs() async throws {
        let (provider, store) = try ToolTestSupport.makeProvider()
        let meetingID = try await store.createMeeting(title: "Bare")

        let result = try await provider.call(
            name: "biscotti_get_meeting",
            arguments: ["id": .string(meetingID.uuidString)]
        )
        let audio = try #require(
            try ToolTestSupport.jsonObject(from: result)["audio_files"] as? [String: Any]
        )
        #expect(audio["present"] as? Bool == false)
        #expect(audio.keys.contains("microphone") == false)
        #expect(audio.keys.contains("system") == false)
    }
}
