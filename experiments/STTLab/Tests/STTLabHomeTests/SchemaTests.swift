import Foundation
import STTLabCore
@testable import STTLabHome
import Testing

@Suite("Home schema round-trips")
struct SchemaTests {
    @Test("SelectionEntry round-trips through JSON")
    func selectionEntryRoundTrip() throws {
        let entry = SelectionEntry(
            meetingUUID: UUID(),
            title: "Test meeting",
            date: Date(timeIntervalSinceReferenceDate: 100_000),
            durationSeconds: 1800,
            speakerCount: 3,
            wordCount: 2500,
            wordsPerMinute: 100,
            language: "en",
            bucket: .short,
            appleLocale: "en_US",
            meetingID: "m01"
        )

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601

        let data = try encoder.encode(entry)
        let decoded = try decoder.decode(SelectionEntry.self, from: data)
        #expect(decoded == entry)
    }

    @Test("SelectionFile round-trips through JSONFiles")
    func selectionFileRoundTrip() throws {
        // Use JSONFiles (prettyPrinted + sortedKeys + ISO-8601) for the round-trip,
        // and verify field-by-field to avoid floating-point Date equality issues.
        let meetingUUID = UUID()
        let file = SelectionFile(
            createdAt: Date(timeIntervalSinceReferenceDate: 1000),
            notes: ["test note"],
            meetings: [
                SelectionEntry(
                    meetingUUID: meetingUUID,
                    title: "A",
                    date: Date(timeIntervalSinceReferenceDate: 0),
                    durationSeconds: 1800,
                    speakerCount: 2,
                    wordCount: 1000,
                    wordsPerMinute: 100,
                    language: "en",
                    bucket: .long,
                    appleLocale: "en_US",
                    meetingID: "m01"
                )
            ],
            alternates: [],
            confirmed: true,
            confirmedAt: Date(timeIntervalSinceReferenceDate: 500),
            confirmedHash: "abc123"
        )

        let tmpURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("sttlab-test-schema-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: tmpURL) }

        try JSONFiles.write(file, to: tmpURL)
        let decoded: SelectionFile = try JSONFiles.read(from: tmpURL)

        #expect(decoded.schemaVersion == file.schemaVersion)
        #expect(decoded.notes == file.notes)
        #expect(decoded.meetings.count == 1)
        #expect(decoded.meetings[0].meetingUUID == meetingUUID)
        #expect(decoded.meetings[0].title == "A")
        #expect(decoded.meetings[0].bucket == .long)
        #expect(decoded.meetings[0].meetingID == "m01")
        #expect(decoded.confirmed == true)
        #expect(decoded.confirmedHash == "abc123")
    }

    @Test("SourceInfo round-trips through JSON")
    func sourceInfoRoundTrip() throws {
        let info = SourceInfo(
            meetingUUID: UUID(),
            title: "Source test",
            date: Date(timeIntervalSinceReferenceDate: 12345),
            micPath: "/path/to/mic.aac",
            systemPath: "/path/to/system.aac"
        )

        let tmpURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("sttlab-test-source-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: tmpURL) }

        try JSONFiles.write(info, to: tmpURL)
        let decoded: SourceInfo = try JSONFiles.read(from: tmpURL)
        #expect(decoded == info)
    }

    @Test("Bucket enum round-trips")
    func bucketRoundTrip() throws {
        let encoder = JSONEncoder()
        let decoder = JSONDecoder()
        for bucket in [Bucket.short, Bucket.long] {
            let data = try encoder.encode(bucket)
            let decoded = try decoder.decode(Bucket.self, from: data)
            #expect(decoded == bucket)
        }
    }

    @Test("ReferenceStatus round-trips through JSONFiles")
    func referenceStatusRoundTrip() throws {
        let status = ReferenceStatus(
            meetingID: "m03",
            status: .completed,
            model: "microsoft/mai-transcribe-2",
            zdr: true,
            chunkCount: 4,
            completedChunks: 4,
            totalCost: 0.0234,
            wordsPresent: true
        )

        let tmpURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("sttlab-test-refstatus-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: tmpURL) }

        try JSONFiles.write(status, to: tmpURL)
        let decoded: ReferenceStatus = try JSONFiles.read(from: tmpURL)

        #expect(decoded == status)
        #expect(decoded.model == "microsoft/mai-transcribe-2")
        #expect(decoded.totalCost == 0.0234)
        #expect(decoded.wordsPresent == true)
    }

    @Test("ChunkMeta round-trips through JSONFiles")
    func chunkMetaRoundTrip() throws {
        let meta = ChunkMeta(
            chunkIndex: 0,
            startSample: 0,
            endSample: 4_800_000,
            startSeconds: 0,
            endSeconds: 300,
            requestMetadata: ["model": "test", "zdr": "true"],
            httpStatus: 200,
            responseHeaders: ["Content-Type": "application/json"],
            attempts: 1,
            latencySeconds: 12.5,
            requestedAt: Date(timeIntervalSinceReferenceDate: 5000)
        )

        let tmpURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("sttlab-test-chunkmeta-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: tmpURL) }

        try JSONFiles.write(meta, to: tmpURL)
        let decoded: ChunkMeta = try JSONFiles.read(from: tmpURL)

        #expect(decoded == meta)
        #expect(decoded.chunkIndex == 0)
        #expect(decoded.attempts == 1)
        #expect(decoded.httpStatus == 200)
    }

    @Test("ChunkPlan round-trips through JSONFiles")
    func chunkPlanRoundTrip() throws {
        let plan = ChunkPlan(
            sampleRate: 16000,
            chunks: [
                ChunkPlan.Chunk(index: 0, startSample: 0, endSample: 4_800_000, cutRMS: 0.001),
                ChunkPlan.Chunk(index: 1, startSample: 4_800_000, endSample: 9_600_000, cutRMS: nil)
            ]
        )

        let tmpURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("sttlab-test-chunkplan-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: tmpURL) }

        try JSONFiles.write(plan, to: tmpURL)
        let decoded: ChunkPlan = try JSONFiles.read(from: tmpURL)

        #expect(decoded == plan)
        #expect(decoded.chunks.count == 2)
        #expect(decoded.chunks[0].cutRMS == 0.001)
        #expect(decoded.chunks[1].cutRMS == nil)
    }

    @Test("ReferenceConfig fields have correct defaults")
    func referenceConfigDefaults() {
        let config = ReferenceConfig()
        #expect(config.model == "microsoft/mai-transcribe-2")
        #expect(config.zdr == true)
        #expect(config.chunkSeconds == 300)
        #expect(config.pricePerHour == 0.10)
    }
}
