import DataStore
import Formatting
import Foundation
import Testing
@testable import ImportExport

@Suite("MeetingCSVExporter")
struct MeetingCSVExporterTests {
    private func makeStore() throws -> DataStore {
        try DataStore(storage: .inMemory)
    }

    private func makeTempDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appending(path: UUID().uuidString, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(
            at: url,
            withIntermediateDirectories: true
        )
        return url
    }

    private func readText(_ url: URL) throws -> String {
        try String(contentsOf: url, encoding: .utf8)
    }

    private func seedMeeting(
        _ store: DataStore,
        id: UUID = UUID(),
        title: String,
        created: Date = Date(timeIntervalSince1970: 1_750_000_000),
        summary: String = "",
        notes: String = "",
        transcript: [TranscriptSegmentDraft] = []
    ) async throws -> UUID {
        try await store.insertImportedMeetings(
            [
                ImportedMeetingDraft(
                    meetingID: id,
                    title: title,
                    created: created,
                    summary: summary,
                    notes: notes,
                    transcript: transcript
                )
            ],
            batchID: 1
        )
        return id
    }

    private func rows(in text: String) throws -> [[String]] {
        try CSVParser.parse(text)
    }

    @Test("An empty store exports a header-only file")
    func emptyStoreHeaderOnly() async throws {
        let store = try makeStore()
        let directory = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let url = try await MeetingCSVExporter(store: store).export(to: directory)

        #expect(try readText(url) == "id,title,created,summary,notes,transcript\r\n")
    }

    @Test("Meetings export newest-first")
    func newestFirstOrder() async throws {
        let store = try makeStore()
        let directory = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let base = 1_750_000_000.0
        let oldest = try await seedMeeting(
            store, title: "Old", created: Date(timeIntervalSince1970: base)
        )
        let newest = try await seedMeeting(
            store, title: "New", created: Date(timeIntervalSince1970: base + 1000)
        )
        let middle = try await seedMeeting(
            store, title: "Middle", created: Date(timeIntervalSince1970: base + 500)
        )

        let url = try await MeetingCSVExporter(store: store).export(to: directory)
        let dataRows = try Array(rows(in: readText(url)).dropFirst())

        #expect(dataRows.compactMap { UUID(uuidString: $0[0]) } == [newest, middle, oldest])
        #expect(dataRows.map { $0[1] } == ["New", "Middle", "Old"])
    }

    @Test("Fields containing commas, quotes, and newlines are escaped")
    func escaping() async throws {
        let store = try makeStore()
        let directory = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let id = try await seedMeeting(
            store,
            title: "Q3 Review, part 2",
            summary: "He said \"hi\"",
            notes: "line1\nline2"
        )

        let url = try await MeetingCSVExporter(store: store).export(to: directory)
        let row = try #require(try rows(in: readText(url)).last)

        #expect(row[0] == id.uuidString)
        #expect(row[1] == "Q3 Review, part 2")
        #expect(row[3] == "He said \"hi\"")
        #expect(row[4] == "line1\nline2")
    }

    @Test("A meeting with no transcript writes an empty final field")
    func noTranscriptEmptyField() async throws {
        let store = try makeStore()
        let directory = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        _ = try await store.createMeeting(title: "Bare")

        let url = try await MeetingCSVExporter(store: store).export(to: directory)
        let row = try #require(try rows(in: readText(url)).last)

        #expect(row.count == 6)
        #expect(row[5] == "")
    }

    @Test("Chunked exports are byte-identical to single-chunk exports")
    func chunking() async throws {
        let store = try makeStore()
        for index in 0 ..< 5 {
            _ = try await seedMeeting(
                store,
                title: "Meeting \(index)",
                created: Date(timeIntervalSince1970: 1_750_000_000 + Double(index)),
                transcript: [
                    TranscriptSegmentDraft(
                        speakerID: 0,
                        speakerLabel: "Speaker 0",
                        startTime: TimeInterval(index * 10),
                        text: "Turn \(index)."
                    )
                ]
            )
        }

        let smallChunksDirectory = try makeTempDirectory()
        let bigChunksDirectory = try makeTempDirectory()
        defer {
            try? FileManager.default.removeItem(at: smallChunksDirectory)
            try? FileManager.default.removeItem(at: bigChunksDirectory)
        }

        let small = try await MeetingCSVExporter(store: store, chunkSize: 2)
            .export(to: smallChunksDirectory)
        let big = try await MeetingCSVExporter(store: store, chunkSize: 50)
            .export(to: bigChunksDirectory)

        let smallText = try readText(small)
        let bigText = try readText(big)
        #expect(smallText == bigText)
        #expect(try rows(in: smallText).count == 6)
    }

    @Test("The filename is Biscotti_export_{yyyy-MM-dd-HHmmss}.csv in local time")
    func fileNameShape() throws {
        var components = DateComponents()
        components.year = 2026
        components.month = 9
        components.day = 1
        components.hour = 14
        components.minute = 26
        components.second = 42

        let now = try #require(Calendar.current.date(from: components))
        #expect(
            MeetingCSVExporter.fileName(for: now)
                == "Biscotti_export_2026-09-01-142642.csv"
        )
    }

    @Test("An export scans back to the same meetings and transcript text")
    func exportScansBack() async throws {
        let store = try makeStore()
        let withTranscript = UUID()
        let segments = [
            TranscriptSegmentDraft(
                speakerID: 0, speakerLabel: "Steve", startTime: 23, text: "Let's get started."
            ),
            TranscriptSegmentDraft(
                speakerID: 1, speakerLabel: "Priya", startTime: 31, text: "I pushed the fix."
            ),
            TranscriptSegmentDraft(
                speakerID: 0, speakerLabel: "Steve", startTime: 40, text: "Great."
            )
        ]
        _ = try await seedMeeting(
            store,
            id: withTranscript,
            title: "Standup",
            summary: "Recap",
            transcript: segments
        )
        let bare = try await seedMeeting(store, title: "Bare")

        let directory = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = try await MeetingCSVExporter(store: store).export(to: directory)

        let result = MeetingCSVImporter.scan(
            fileURL: url,
            existing: ExistingMeetingIdentity()
        )
        #expect(result.criticalErrors.isEmpty)
        // The bare meeting has no summary, notes, or transcript.
        #expect(result.warnings == [.emptyContent(count: 1)])
        #expect(Set(result.drafts.map(\.meetingID)) == [withTranscript, bare])

        let transcriptDraft = try #require(
            result.drafts.first { $0.meetingID == withTranscript }
        )
        #expect(transcriptDraft.title == "Standup")
        #expect(transcriptDraft.summary == "Recap")
        #expect(
            transcriptDraft.created == Date(timeIntervalSince1970: 1_750_000_000)
        )

        // Round-trip: rendering the scanned segments reproduces the
        // rendered transcript the export wrote (speakers, times, words).
        #expect(
            TranscriptTextFormatting.render(segmentData(transcriptDraft.transcript))
                == TranscriptTextFormatting.render(segmentData(segments))
        )
    }

    private func segmentData(
        _ drafts: [TranscriptSegmentDraft]
    ) -> [SegmentData] {
        drafts.map {
            SegmentData(
                id: UUID(),
                speakerID: $0.speakerID,
                speakerLabel: $0.speakerLabel,
                startTime: $0.startTime,
                endTime: $0.startTime,
                text: $0.text
            )
        }
    }
}
