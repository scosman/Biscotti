import CoreGraphics
import Testing
@testable import TranscriptUI

@Suite("VisibleRowTracker")
struct VisibleRowTrackerTests {
    @Test("the top visible item is the first row whose middle is on screen")
    func topVisibleIsFirstRowWhoseMiddleIsOnScreen() {
        let tracker = VisibleRowTracker()
        tracker.updateHeader(height: 300)
        tracker.updateScroll(offsetY: 900, insetTop: 0)
        // Overscanned above, mostly scrolled off, on screen, and below.
        tracker.update(id: "above", startTime: 10, frame: CGRect(x: 0, y: -120, width: 100, height: 50))
        tracker.update(id: "mostlyOff", startTime: 20, frame: CGRect(x: 0, y: -40, width: 100, height: 50))
        tracker.update(id: "top", startTime: 30, frame: CGRect(x: 0, y: 14, width: 100, height: 50))
        tracker.update(id: "next", startTime: 40, frame: CGRect(x: 0, y: 70, width: 100, height: 50))

        #expect(tracker.topVisibleStartTime == 30)

        tracker.remove(id: "top")
        #expect(tracker.topVisibleStartTime == 40)
    }

    @Test("while the header is visible there is no anchor")
    func headerVisibleGivesNoAnchor() {
        let tracker = VisibleRowTracker()
        tracker.update(id: "first", startTime: 0, frame: CGRect(x: 0, y: 300, width: 100, height: 50))
        #expect(tracker.topVisibleStartTime == nil)

        tracker.updateHeader(height: 280)
        tracker.updateScroll(offsetY: 279, insetTop: 0)
        #expect(tracker.topVisibleStartTime == nil)

        tracker.updateScroll(offsetY: 280, insetTop: 0)
        #expect(tracker.topVisibleStartTime == 0)
    }

    @Test("a jump past the header hides it without a header geometry report")
    func jumpPastHeaderHidesIt() {
        let tracker = VisibleRowTracker()
        tracker.updateHeader(height: 280)
        tracker.update(id: "deep", startTime: 600, frame: CGRect(x: 0, y: 10, width: 100, height: 50))

        // End or Page Down: only the scroll position is reported.
        tracker.updateScroll(offsetY: 5000, insetTop: 0)

        #expect(tracker.isHeaderVisible == false)
        #expect(tracker.topVisibleStartTime == 600)
    }
}

@Suite("VisibleRowTracker -- toolbar inset")
struct VisibleRowTrackerInsetTests {
    /// The app's layout: the `List` runs 52 pt under the toolbar, so at rest
    /// the content offset is -52 and the reader's top edge is y = 52.
    private let insetTop: CGFloat = 52

    @Test("rows under the toolbar are not the top visible row")
    func rowsUnderTheToolbarAreSkipped() {
        let tracker = VisibleRowTracker()
        tracker.updateHeader(height: 280)
        tracker.updateScroll(offsetY: 1000, insetTop: insetTop)
        // Rows 18 and 19 are under the toolbar; row 20 is the first one seen.
        tracker.update(id: "18", startTime: 72, frame: CGRect(x: 0, y: -14, width: 100, height: 33))
        tracker.update(id: "19", startTime: 76, frame: CGRect(x: 0, y: 19, width: 100, height: 33))
        tracker.update(id: "20", startTime: 80, frame: CGRect(x: 0, y: 52, width: 100, height: 33))
        tracker.update(id: "21", startTime: 84, frame: CGRect(x: 0, y: 85, width: 100, height: 33))

        #expect(tracker.topVisibleStartTime == 80)
    }

    @Test("the header counts as visible only while it shows below the toolbar")
    func headerUnderTheToolbarIsHidden() {
        let tracker = VisibleRowTracker()
        tracker.updateHeader(height: 280)
        tracker.update(id: "first", startTime: 0, frame: CGRect(x: 0, y: 300, width: 100, height: 33))

        // At rest: offset -52, the header's top is just below the toolbar.
        tracker.updateScroll(offsetY: -insetTop, insetTop: insetTop)
        #expect(tracker.isHeaderVisible)

        // The header's last point is just below the toolbar.
        tracker.updateScroll(offsetY: 280 - insetTop - 1, insetTop: insetTop)
        #expect(tracker.isHeaderVisible)

        // The header has scrolled fully under the toolbar.
        tracker.updateScroll(offsetY: 280 - insetTop, insetTop: insetTop)
        #expect(!tracker.isHeaderVisible)
        #expect(tracker.topVisibleStartTime == 0)
    }
}
