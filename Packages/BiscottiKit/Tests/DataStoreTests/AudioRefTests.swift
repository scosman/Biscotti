import DataStore
import Foundation
import Testing

@Suite("Audio file references")
struct AudioRefTests {
    private func makeStore() throws -> DataStore {
        try DataStore(storage: .inMemory)
    }

    @Test("Attach audio refs with mic and system roles")
    func attachRefs() async throws {
        let store = try makeStore()
        let meetingID = try await store.createMeeting(title: "Audio test")

        let mic = AudioFileRef(role: .mic, path: "/tmp/mic.aac", byteSize: 1024)
        let system = AudioFileRef(role: .system, path: "/tmp/system.aac", byteSize: 2048)

        try await store.attachAudio([mic, system], to: meetingID)

        try await store.read { store in
            let meeting = try store.meeting(id: meetingID)
            #expect(meeting?.audioFiles.count == 2)

            let roles = Set((meeting?.audioFiles ?? []).map(\.role))
            #expect(roles.contains(.mic))
            #expect(roles.contains(.system))
        }
    }

    @Test("markAudioPresence detects missing files")
    func markPresenceMissing() async throws {
        let store = try makeStore()
        let meetingID = try await store.createMeeting(title: "Presence check")

        // Use a path that definitely does not exist
        let ref = AudioFileRef(
            role: .mic,
            path: "/tmp/nonexistent-audio-file-\(UUID().uuidString).aac",
            byteSize: 1000,
            isPresent: true
        )
        try await store.attachAudio([ref], to: meetingID)

        try await store.markAudioPresence(meetingID: meetingID)

        try await store.read { store in
            let meeting = try store.meeting(id: meetingID)
            let audioRef = meeting?.audioFiles.first
            #expect(audioRef?.isPresent == false)
            #expect(audioRef?.byteSize == 0)
        }
    }

    @Test("markAudioPresence detects existing files and updates byteSize")
    func markPresenceExists() async throws {
        let store = try makeStore()
        let meetingID = try await store.createMeeting(title: "Presence exists")

        // Write a real temp file
        let tmpDir = FileManager.default.temporaryDirectory
        let filePath = tmpDir.appendingPathComponent("test-audio-\(UUID().uuidString).aac")
        let data = Data(repeating: 0xAB, count: 512)
        try data.write(to: filePath)
        defer { try? FileManager.default.removeItem(at: filePath) }

        let ref = AudioFileRef(
            role: .system,
            path: filePath.path,
            byteSize: 0,
            isPresent: false
        )
        try await store.attachAudio([ref], to: meetingID)

        try await store.markAudioPresence(meetingID: meetingID)

        try await store.read { store in
            let meeting = try store.meeting(id: meetingID)
            let audioRef = meeting?.audioFiles.first
            #expect(audioRef?.isPresent == true)
            #expect(audioRef?.byteSize == 512)
        }
    }

    @Test("attachAudio to non-existent meeting throws notFound")
    func attachToMissing() async throws {
        let store = try makeStore()
        let bogus = UUID()
        await #expect(throws: DataStoreError.notFound(bogus)) {
            let ref = AudioFileRef(role: .mic, path: "/tmp/test.aac", byteSize: 100)
            try await store.attachAudio([ref], to: bogus)
        }
    }

    @Test("markAudioPresence on non-existent meeting throws notFound")
    func markPresenceMissing_meeting() async throws {
        let store = try makeStore()
        let bogus = UUID()
        await #expect(throws: DataStoreError.notFound(bogus)) {
            try await store.markAudioPresence(meetingID: bogus)
        }
    }

    @Test("Attaching additional refs appends without replacing")
    func appendDoesNotReplace() async throws {
        let store = try makeStore()
        let meetingID = try await store.createMeeting(title: "Append test")

        let mic = AudioFileRef(role: .mic, path: "/tmp/mic.aac", byteSize: 100)
        try await store.attachAudio([mic], to: meetingID)

        let system = AudioFileRef(role: .system, path: "/tmp/sys.aac", byteSize: 200)
        try await store.attachAudio([system], to: meetingID)

        try await store.read { store in
            let meeting = try store.meeting(id: meetingID)
            #expect(meeting?.audioFiles.count == 2)
        }
    }

    // MARK: - storedAudioFileRefs

    @Test("storedAudioFileRefs keeps deleted files' paths with present false")
    func storedRefsKeepDeletedPaths() async throws {
        let store = try makeStore()
        let meetingID = try await store.createMeeting(title: "Stored refs")

        try await store.attachAudio(
            [AudioFileRef(role: .mic, path: "/gone/mic.aac", byteSize: 0, isPresent: false),
             AudioFileRef(role: .system, path: "/gone/system.aac", byteSize: 0, isPresent: false)],
            to: meetingID
        )

        let stored = try await store.storedAudioFileRefs(meetingID: meetingID)
        #expect(stored.present == false)
        #expect(stored.mic?.path == "/gone/mic.aac")
        #expect(stored.system?.path == "/gone/system.aac")

        // Contrast: the presence-filtered variant drops the deleted files.
        let playable = try await store.audioFileRefs(meetingID: meetingID)
        #expect(playable.present == false)
        #expect(playable.mic == nil)
        #expect(playable.system == nil)
    }

    @Test("storedAudioFileRefs reports mixed presence per file")
    func storedRefsMixedPresence() async throws {
        let store = try makeStore()
        let meetingID = try await store.createMeeting(title: "Mixed refs")
        try await store.attachAudio(
            [AudioFileRef(role: .mic, path: "/kept/mic.aac", byteSize: 100, isPresent: true),
             AudioFileRef(role: .system, path: "/gone/system.aac", byteSize: 0, isPresent: false)],
            to: meetingID
        )

        let stored = try await store.storedAudioFileRefs(meetingID: meetingID)
        #expect(stored.present == true)
        #expect(stored.mic?.path == "/kept/mic.aac")
        #expect(stored.system?.path == "/gone/system.aac")
    }

    @Test("storedAudioFileRefs returns nils when there are no refs at all")
    func storedRefsNoRefs() async throws {
        let store = try makeStore()
        let meetingID = try await store.createMeeting(title: "No refs")

        let stored = try await store.storedAudioFileRefs(meetingID: meetingID)
        #expect(stored.present == false)
        #expect(stored.mic == nil)
        #expect(stored.system == nil)
    }
}
