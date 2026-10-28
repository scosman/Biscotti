import Foundation
import Testing
@testable import LiveTranscriptModel

@Suite("LiveTranscriptSnapshot")
struct LiveTranscriptSnapshotTests {
    private let rows = [
        LiveRow(track: .mic, startTime: 1, endTime: 2, settledText: "Hello", tailText: " there"),
        LiveRow(track: .system, startTime: 2, endTime: 3, tailText: "maybe"),
        LiveRow(track: .system, startTime: 3, endTime: 3),
        LiveRow(track: .mic, startTime: 4, endTime: 5, settledText: "Done.", isClosed: true)
    ]

    private func snapshot(includeTail: Bool) -> LiveTranscriptSnapshot {
        LiveTranscriptSnapshot(
            sessionID: UUID(),
            revision: 3,
            captureWatermark: 6,
            transcribedThrough: 5.5,
            settledThrough: 5,
            rows: rows,
            gaps: [LiveGap(track: .mic, startTime: 5, duration: 1, reason: .captureGap)],
            includesTail: includeTail
        )
    }

    @Test("Without the tail, tails are stripped and rows left empty are dropped")
    func snapshotWithoutTailStripsTailAndDropsEmptyRows() {
        let settledOnly = snapshot(includeTail: false)
        #expect(!settledOnly.includesTail)
        #expect(settledOnly.rows.map(\.settledText) == ["Hello", "Done."])
        #expect(settledOnly.rows.map(\.tailText) == ["", ""])
        #expect(settledOnly.rows.map(\.id) == [rows[0].id, rows[3].id])
        #expect(settledOnly.gaps.count == 1)
    }

    @Test("With the tail, rows keep their tails and only rows with no text are dropped")
    func snapshotWithTailKeepsTailAndDropsOnlyEmptyRows() {
        let withTail = snapshot(includeTail: true)
        #expect(withTail.includesTail)
        #expect(withTail.rows == [rows[0], rows[1], rows[3]])
    }
}

@Suite("LiveTranscriptSnapshot order")
struct LiveTranscriptSnapshotOrderTests {
    @Test("Rows come out in start-time order; rows that start together keep their order")
    func rowsAreSortedByStartTime() {
        let late = LiveRow(track: .mic, startTime: 4, endTime: 5, settledText: "Later.")
        let first = LiveRow(track: .system, startTime: 1, endTime: 2, settledText: "First")
        let tieA = LiveRow(track: .mic, startTime: 2, endTime: 3, settledText: "A")
        let tieB = LiveRow(track: .system, startTime: 2, endTime: 3, settledText: "B")
        let snapshot = LiveTranscriptSnapshot(
            sessionID: UUID(), revision: 1, captureWatermark: 5, transcribedThrough: 5, settledThrough: 5,
            rows: [late, first, tieA, tieB], gaps: [], includesTail: true
        )
        #expect(snapshot.rows.map(\.id) == [first.id, tieA.id, tieB.id, late.id])
    }
}
