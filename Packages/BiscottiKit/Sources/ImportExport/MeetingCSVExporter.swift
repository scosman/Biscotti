import DataStore
import Formatting
import Foundation

/// Writes every meeting in the store to a CSV file (functional spec §5),
/// streaming in chunks so memory stays bounded regardless of library size
/// — a few thousand meetings with long transcripts would otherwise be
/// hundreds of megabytes of `String` (architecture §4.3).
public struct MeetingCSVExporter: Sendable {
    private let source: any MeetingExportSource
    private let chunkSize: Int

    public init(store: DataStore, chunkSize: Int = 50) {
        self.init(source: store, chunkSize: chunkSize)
    }

    /// Test entry point: any source, so a failing chunk fetch can exercise
    /// the partial-file cleanup path.
    init(source: any MeetingExportSource, chunkSize: Int) {
        self.source = source
        // A non-positive chunk size is a caller mistake, not a reason to
        // trap a release build.
        self.chunkSize = max(1, chunkSize)
    }

    /// Writes the CSV to `directory` and returns the file URL.
    ///
    /// The file is named `Biscotti_export_{yyyy-MM-dd-HHmmss}.csv` (local
    /// time) at creation, so the temp file already carries the name the
    /// save dialog will offer. Any failure removes the partial file.
    public func export(
        to directory: URL = URL.temporaryDirectory,
        now: Date = Date()
    ) async throws -> URL {
        let fileURL = directory.appending(path: Self.fileName(for: now))

        // Creates or truncates, and throws the real underlying error when
        // the directory is missing or the file is unwritable — no
        // Bool-returning createFile to reinterpret.
        try Data().write(to: fileURL)

        var completed = false
        defer {
            if !completed {
                try? FileManager.default.removeItem(at: fileURL)
            }
        }

        do {
            let handle = try FileHandle(forWritingTo: fileURL)
            var exported = 0
            do {
                try handle.write(contentsOf: Data(CSVColumns.headerRow.utf8))

                let ids = try await source.meetingIDsForExport()
                for start in stride(from: 0, to: ids.count, by: chunkSize) {
                    let end = min(start + chunkSize, ids.count)
                    let meetings = try await source.exportData(
                        for: Array(ids[start ..< end])
                    )

                    var text = ""
                    for meeting in meetings {
                        text += Self.row(for: meeting)
                    }
                    try handle.write(contentsOf: Data(text.utf8))
                    exported += meetings.count
                }
                // Close explicitly on the success path so a close failure
                // surfaces instead of reporting a successful export of a
                // possibly unwritten file.
                try handle.close()
            } catch {
                try? handle.close()
                throw error
            }

            completed = true
            importExportLog.info("CSV export wrote \(exported) meetings")
            return fileURL
        } catch {
            importExportLog.error(
                "CSV export failed: \(String(describing: error), privacy: .public)"
            )
            throw error
        }
    }

    // MARK: - Row Building

    private static func row(for meeting: MeetingExportData) -> String {
        CSVWriter.row([
            meeting.id.uuidString,
            meeting.title,
            ISO8601Formatting.string(from: meeting.date),
            meeting.summary,
            meeting.notes,
            TranscriptTextFormatting.render(
                meeting.segments,
                names: meeting.speakerNames
            )
        ])
    }

    /// `Biscotti_export_2026-09-01-142642.csv` — local time (functional
    /// spec §5.2). The formatter is created per call: `DateFormatter` is
    /// not `Sendable`, so a cached static would not compile under Swift 6
    /// strict concurrency (the `ISO8601Formatting` precedent).
    static func fileName(for now: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd-HHmmss"
        formatter.timeZone = .current
        return "Biscotti_export_\(formatter.string(from: now)).csv"
    }
}

/// The store surface the exporter reads. Internal so tests can stand in a
/// failing source; `DataStore` conforms through its existing
/// import/export methods.
protocol MeetingExportSource: Sendable {
    func meetingIDsForExport() async throws -> [UUID]
    func exportData(for ids: [UUID]) async throws -> [MeetingExportData]
}

extension DataStore: MeetingExportSource {}
