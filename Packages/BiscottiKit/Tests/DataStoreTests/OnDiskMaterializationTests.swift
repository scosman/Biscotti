import DataStore
import Foundation
import Testing
import Transcription

/// Regression tests for the SwiftData array-of-primitive materialization bug.
///
/// SwiftData `@Model` classes in SPM modules cannot materialize `Array<String>`
/// attributes from on-disk stores — the runtime fails to resolve the generic
/// `Array` value transformer by name. In-memory stores use a different
/// serialization path that masks the issue, which is why the existing unit tests
/// passed while the real app faulted at runtime.
///
/// These tests write to a real on-disk SQLite store, close it, reopen it from
/// the same URL, and verify the round-trip. They would have FAILED before the
/// `Data`-backed fix and PASS after.
@Suite("On-disk materialization regression")
struct OnDiskMaterializationTests {
    // MARK: - Helpers

    /// Creates a unique temp directory for each test.
    private func makeTempDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("OnDiskMaterializationTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private func makeResult(methodId: String = "v1") -> TranscriptResult {
        TranscriptResult(
            transcriptionMethodId: methodId,
            language: "en",
            speakerCount: 1,
            segments: [
                TranscriptSegment(
                    speakerID: 0,
                    speakerLabel: "Speaker 0",
                    startTime: 0,
                    endTime: 5,
                    text: "Hello world",
                    confidence: 0.9,
                    noSpeechProbability: 0.01,
                    words: nil
                )
            ],
            speakerEmbeddings: [:],
            processingDuration: 1.0
        )
    }

    // MARK: - TranscriptRecord.vocabularyUsed

    @Test("vocabularyUsed round-trips through on-disk store")
    func vocabularyUsedOnDiskRoundTrip() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let vocab = ["Biscotti", "Anthropic"]
        let meetingID: UUID

        // Write: create store, insert a transcript with non-empty vocabulary, save.
        do {
            let store = try DataStore(storage: .onDisk(dir))
            meetingID = try await store.createMeeting(title: "Vocab disk test")
            _ = try await store.addTranscript(
                makeResult(),
                vocabularyUsed: vocab,
                mappedEventIdentifier: nil,
                to: meetingID
            )
        }

        // Read: open a fresh DataStore on the same URL, fetch and verify.
        do {
            let store2 = try DataStore(storage: .onDisk(dir))
            try await store2.read { store in
                let meeting = try store.meeting(id: meetingID)
                let transcript = meeting?.transcripts.first
                #expect(transcript != nil, "transcript should exist on disk")
                #expect(transcript?.vocabularyUsed == vocab)
            }
        }
    }

    @Test("empty vocabularyUsed round-trips through on-disk store")
    func emptyVocabularyUsedOnDiskRoundTrip() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let meetingID: UUID

        do {
            let store = try DataStore(storage: .onDisk(dir))
            meetingID = try await store.createMeeting(title: "Empty vocab disk test")
            _ = try await store.addTranscript(
                makeResult(),
                vocabularyUsed: [],
                mappedEventIdentifier: nil,
                to: meetingID
            )
        }

        do {
            let store2 = try DataStore(storage: .onDisk(dir))
            try await store2.read { store in
                let meeting = try store.meeting(id: meetingID)
                let transcript = meeting?.transcripts.first
                #expect(transcript != nil)
                #expect(transcript?.vocabularyUsed == [])
            }
        }
    }

    // MARK: - AppSettings.customVocabulary

    @Test("customVocabulary round-trips through on-disk store")
    func customVocabularyOnDiskRoundTrip() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let vocab = ["WhisperKit", "SpeakerKit", "ArgMax"]

        // Write: create store, insert AppSettings with non-empty vocabulary.
        do {
            let store = try DataStore(storage: .onDisk(dir))
            let settings = AppSettings(customVocabulary: vocab, launchAtLogin: true)
            try await store.insertSettings(settings)
        }

        // Read: open a fresh DataStore, fetch AppSettings back.
        do {
            let store2 = try DataStore(storage: .onDisk(dir))
            try await store2.read { store in
                let fetched = try store.fetchAllSettings().first
                #expect(fetched != nil, "AppSettings should exist on disk")
                #expect(fetched?.customVocabulary == vocab)
                #expect(fetched?.launchAtLogin == true)
            }
        }
    }

    @Test("empty customVocabulary round-trips through on-disk store")
    func emptyCustomVocabularyOnDiskRoundTrip() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        do {
            let store = try DataStore(storage: .onDisk(dir))
            let settings = AppSettings()
            try await store.insertSettings(settings)
        }

        do {
            let store2 = try DataStore(storage: .onDisk(dir))
            try await store2.read { store in
                let fetched = try store.fetchAllSettings().first
                #expect(fetched != nil)
                #expect(fetched?.customVocabulary == [])
            }
        }
    }

    // MARK: - Staleness comparison still works

    @Test("preferredTranscriptIsStale works with on-disk vocabularyUsed")
    func stalenessCheckOnDisk() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let vocab = ["Biscotti"]
        let meetingID: UUID
        let transcriptID: UUID

        do {
            let store = try DataStore(storage: .onDisk(dir))
            meetingID = try await store.createMeeting(title: "Staleness disk test")
            transcriptID = try await store.addTranscript(
                makeResult(methodId: "v1"),
                vocabularyUsed: vocab,
                mappedEventIdentifier: nil,
                to: meetingID
            )
            try await store.setPreferredTranscript(transcriptID, for: meetingID)
        }

        do {
            let store2 = try DataStore(storage: .onDisk(dir))

            // Same inputs => not stale
            let notStale = try await store2.preferredTranscriptIsStale(
                meetingID: meetingID,
                currentMethodId: "v1",
                currentVocabulary: vocab,
                currentEventIdentifier: nil
            )
            #expect(notStale == false)

            // Different vocab => stale
            let stale = try await store2.preferredTranscriptIsStale(
                meetingID: meetingID,
                currentMethodId: "v1",
                currentVocabulary: ["NewTerm"],
                currentEventIdentifier: nil
            )
            #expect(stale == true)
        }
    }
}
