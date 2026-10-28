import Testing
@testable import TranscriptUI

/// The draft-to-final swap waits while text is selected in a bubble. Row 0
/// is the header only when the list has one.
@Suite("Focus probe -- which rows hold bubbles")
@MainActor
struct FocusProbeTests {
    @Test("With a header, row 0 is ruled out; rows after it and unplaced views count")
    func headerRowIsRuledOut() {
        #expect(!FocusProbeView.rowHoldsBubble(0, hasHeaderRow: true))
        #expect(FocusProbeView.rowHoldsBubble(1, hasHeaderRow: true))
        #expect(FocusProbeView.rowHoldsBubble(-1, hasHeaderRow: true), "when unsure, the swap waits")
    }

    @Test("Without a header, row 0 is a bubble")
    func rowZeroIsABubbleWithoutHeader() {
        #expect(FocusProbeView.rowHoldsBubble(0, hasHeaderRow: false))
        #expect(FocusProbeView.rowHoldsBubble(-1, hasHeaderRow: false))
    }
}
