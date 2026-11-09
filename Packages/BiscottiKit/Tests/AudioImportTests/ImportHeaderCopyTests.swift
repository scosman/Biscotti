import Foundation
import Testing
@testable import AudioImport

@Suite("ImportHeaderCopy")
struct ImportHeaderCopyTests {
    private let now = Date()

    private func item(
        status: ImportItemStatus, name: String = "file.m4a"
    ) -> ImportItem {
        ImportItem(
            batchID: UUID(),
            displayName: name,
            status: status,
            addedAt: now,
            isPromised: false
        )
    }

    // MARK: - In-progress (run != nil)

    @Test("single file in progress shows 'Importing 1 file' with converting")
    func singleInProgress() {
        let items = [item(status: .converting)]
        let run = ImportRun(startIndex: 0, count: 1)
        let copy = ImportHeaderCopy.make(
            items: items, run: run, runPosition: 1
        )

        #expect(copy.title == "Importing 1 file")
        #expect(copy.status == "converting audio")
        #expect(copy.statusIsMono)
    }

    @Test("multi-file in progress shows position")
    func multiInProgress() {
        let items = [
            item(status: .done(meetingID: UUID())),
            item(status: .converting),
            item(status: .waiting)
        ]
        let run = ImportRun(startIndex: 0, count: 3)
        let copy = ImportHeaderCopy.make(
            items: items, run: run, runPosition: 2
        )

        #expect(copy.title == "Importing 3 files")
        #expect(copy.status == "2 of 3 \u{00B7} converting audio")
        #expect(copy.statusIsMono)
    }

    // MARK: - Complete: all succeeded

    @Test("all done shows 'Imported N files' with transcript status")
    func allDone() {
        let items = [
            item(status: .done(meetingID: UUID())),
            item(status: .done(meetingID: UUID()))
        ]
        let copy = ImportHeaderCopy.make(
            items: items, run: nil, runPosition: nil
        )

        #expect(copy.title == "Imported 2 files")
        #expect(copy.status ==
            "Transcripts and summaries are being written in each meeting.")
        #expect(!copy.statusIsMono)
    }

    @Test("single done shows 'Imported 1 file'")
    func singleDone() {
        let items = [item(status: .done(meetingID: UUID()))]
        let copy = ImportHeaderCopy.make(
            items: items, run: nil, runPosition: nil
        )

        #expect(copy.title == "Imported 1 file")
    }

    // MARK: - Complete: some failed

    @Test("partial failure shows 'Imported X of Y files'")
    func someFailed() {
        let items = [
            item(status: .done(meetingID: UUID())),
            item(status: .failed(.noAudio))
        ]
        let copy = ImportHeaderCopy.make(
            items: items, run: nil, runPosition: nil
        )

        #expect(copy.title == "Imported 1 of 2 files")
        #expect(copy.status ==
            "Transcripts and summaries are being written in each meeting.")
        #expect(!copy.statusIsMono)
    }

    // MARK: - Complete: all failed

    @Test("all failed single file")
    func allFailedSingle() {
        let items = [item(status: .failed(.unreadable))]
        let copy = ImportHeaderCopy.make(
            items: items, run: nil, runPosition: nil
        )

        #expect(copy.title == "Imported 0 of 1 file")
        #expect(copy.status == "Couldn't convert this file.")
        #expect(!copy.statusIsMono)
    }

    @Test("all failed multiple files")
    func allFailedMultiple() {
        let items = [
            item(status: .failed(.noAudio)),
            item(status: .failed(.unreadable))
        ]
        let copy = ImportHeaderCopy.make(
            items: items, run: nil, runPosition: nil
        )

        #expect(copy.title == "Imported 0 of 2 files")
        #expect(copy.status == "Couldn't convert these files.")
    }
}
