import Foundation
import Testing
@testable import TranscriptUI

private func bubbleItem(_ id: String, _ start: TimeInterval, _ end: TimeInterval) -> TranscriptItem {
    TranscriptItem(id: id, kind: .bubble(Bubble(side: .leading, startTime: start, endTime: end, settledText: id)))
}

private func gapItem(_ start: TimeInterval, _ duration: TimeInterval) -> TranscriptItem {
    TranscriptItem(id: "gap-\(Int(start * 1000))", kind: .gap(startTime: start, duration: duration, cause: .notTranscribedLive))
}

/// Content 1000 pt tall in a 200 pt container: the bottom is offset 800.
private func sample(offset: CGFloat, content: CGFloat = 1000) -> ScrollSample {
    ScrollSample(offsetY: offset, contentHeight: content, containerHeight: 200)
}

private let items = [bubbleItem("a", 0, 5), bubbleItem("b", 5, 9), gapItem(9, 3), bubbleItem("c", 12, 15)]

@Suite("FollowController")
@MainActor
struct FollowControllerTests {
    @Test("scrolling up from the bottom stops following")
    func scrollingUpStopsFollowing() {
        let follower = FollowController(mode: .live)
        follower.scrollChanged(sample(offset: 800), latest: items)
        #expect(follower.isFollowing)

        follower.scrollChanged(sample(offset: 600), latest: items)

        #expect(!follower.isFollowing)
        #expect(follower.heldItems == items)
    }

    @Test("reaching the bottom again resumes following")
    func reachingBottomResumesFollowing() {
        let follower = FollowController(mode: .live)
        follower.scrollChanged(sample(offset: 800), latest: items)
        follower.scrollChanged(sample(offset: 500), latest: items)

        follower.scrollChanged(sample(offset: 790), latest: items)

        #expect(follower.isFollowing)
        #expect(follower.heldItems == nil)
        #expect(follower.scrollRequest?.itemID == "c")
        #expect(follower.scrollRequest?.anchor == .bottom)
    }

    @Test("content growing under a following list does not stop following")
    func contentGrowthKeepsFollowing() {
        let follower = FollowController(mode: .live)
        follower.scrollChanged(sample(offset: 800), latest: items)

        // The spike: a growing row leaves the offset where it was.
        follower.scrollChanged(sample(offset: 800, content: 1300), latest: items)

        #expect(follower.isFollowing)
    }

    @Test("new items while following request a scroll to the newest at the bottom")
    func newItemsWhileFollowingRequestTheNewest() {
        let follower = FollowController(mode: .live)
        let more = items + [bubbleItem("d", 15, 18)]

        follower.itemsChanged(more)

        #expect(follower.scrollRequest?.itemID == "d")
        #expect(follower.displayedItems(latest: more) == more)
    }

    @Test("opening find stops following")
    func openingFindStopsFollowing() {
        let follower = FollowController(mode: .live)
        follower.scrollChanged(sample(offset: 800), latest: items)

        follower.findOpened(latest: items)
        // At the bottom, but find is open: still not following.
        follower.scrollChanged(sample(offset: 800), latest: items)

        #expect(!follower.isFollowing)
    }

    @Test("closing find at the bottom resumes following")
    func closingFindAtBottomResumesFollowing() {
        let follower = FollowController(mode: .live)
        follower.scrollChanged(sample(offset: 800), latest: items)
        follower.findOpened(latest: items)

        follower.findClosed(latest: items)

        #expect(follower.isFollowing)
    }

    @Test("closing find returns to live when the list was following before find opened, wherever the match left it")
    func closingFindReturnsToLiveWhenItWasFollowing() {
        let follower = FollowController(mode: .live)
        follower.scrollChanged(sample(offset: 800), latest: items)
        follower.findOpened(latest: items)
        follower.scroll(to: "a", anchor: .center)
        follower.consumeScrollRequest()
        follower.scrollChanged(sample(offset: 0), latest: items)

        follower.findClosed(latest: items)

        #expect(follower.isFollowing)
        #expect(follower.heldItems == nil)
        #expect(follower.scrollRequest?.itemID == "c")
        #expect(follower.scrollRequest?.anchor == .bottom)
    }

    @Test("a reveal while reading back finds rows that arrived after following stopped")
    func revealWhileReadingBackSeesNewerRows() {
        let follower = FollowController(mode: .live)
        follower.scrollChanged(sample(offset: 800), latest: items)
        follower.scrollChanged(sample(offset: 300), latest: items)
        #expect(follower.heldItems == items)
        let grown = items + [bubbleItem("d", 15, 600), bubbleItem("e", 600, 610)]

        follower.reveal(time: 605, latest: grown)

        #expect(follower.scrollRequest?.itemID == "e")
        #expect(follower.heldItems == grown, "the reader sees the row the reveal landed on")
        #expect(!follower.isFollowing)
    }

    @Test("a reveal while find is open keeps its place when find closes")
    func revealDuringFindKeepsItsPlace() {
        let follower = FollowController(mode: .live)
        follower.scrollChanged(sample(offset: 800), latest: items)
        follower.findOpened(latest: items)
        follower.reveal(time: 6, latest: items)
        follower.consumeScrollRequest()
        follower.scrollChanged(sample(offset: 300), latest: items)

        follower.findClosed(latest: items)

        #expect(!follower.isFollowing)
        #expect(follower.scrollRequest == nil)
    }

    @Test("closing find keeps a reader who was reading back where they are")
    func closingFindKeepsReadingBack() {
        let follower = FollowController(mode: .live)
        follower.scrollChanged(sample(offset: 800), latest: items)
        follower.scrollChanged(sample(offset: 300), latest: items)
        follower.findOpened(latest: items)

        follower.findClosed(latest: items)

        #expect(!follower.isFollowing)
        #expect(follower.heldItems == items)
    }

    @Test("a list that lands away from the bottom while it appears scrolls to the newest again instead of stopping")
    func layoutRightAfterAppearingKeepsFollowing() {
        let clock = ManualClock()
        let follower = FollowController(mode: .live, now: { clock.now })
        follower.listAppeared()
        follower.scrollChanged(sample(offset: 800), latest: items)
        follower.consumeScrollRequest()

        // The reopened list resets to its first row while it lays out.
        follower.scrollChanged(sample(offset: 0), latest: items)

        #expect(follower.isFollowing)
        #expect(follower.heldItems == nil)
        #expect(follower.scrollRequest?.itemID == "c")
        #expect(follower.scrollRequest?.anchor == .bottom)
    }

    @Test("once the list has settled, scrolling up stops following again")
    func scrollingUpAfterTheSettleStopsFollowing() {
        let clock = ManualClock()
        let follower = FollowController(mode: .live, now: { clock.now })
        follower.listAppeared()
        follower.scrollChanged(sample(offset: 800), latest: items)
        clock.advance(FollowController.appearanceSettle + .milliseconds(1))

        follower.scrollChanged(sample(offset: 600), latest: items)

        #expect(!follower.isFollowing)
    }

    @Test("reveal stops following, requests the target once, then clears")
    func revealStopsFollowingAndClears() {
        let follower = FollowController(mode: .live)

        follower.reveal(time: 6, latest: items)

        #expect(!follower.isFollowing)
        #expect(follower.scrollRequest?.itemID == "b")
        #expect(follower.scrollRequest?.anchor == .top)
        follower.consumeScrollRequest()
        #expect(follower.scrollRequest == nil)
    }

    @Test("reveal lands on the bubble containing the time, else the nearest one before")
    func revealLandsOnTheContainingBubble() {
        #expect(FollowController.revealTarget(for: 5, in: items) == "b")
        #expect(FollowController.revealTarget(for: 4.99, in: items) == "a")
        #expect(FollowController.revealTarget(for: 20, in: items) == "c")
        #expect(FollowController.revealTarget(for: -1, in: items) == "a")
        #expect(FollowController.revealTarget(for: 1, in: []) == nil)
    }

    @Test("a time inside a gap goes to the gap marker, even under an overlapping bubble")
    func revealInsideAGapGoesToTheGapMarker() {
        #expect(FollowController.revealTarget(for: 10, in: items) == "gap-9000")

        let overlapping = [bubbleItem("long", 8, 14), gapItem(9, 3)]
        #expect(FollowController.revealTarget(for: 10, in: overlapping) == "gap-9000")
    }

    @Test("reading back holds the items on screen until Return to live")
    func readingBackHoldsItemsUntilReturnToLive() {
        let follower = FollowController(mode: .live)
        follower.scrollChanged(sample(offset: 800), latest: items)
        follower.scrollChanged(sample(offset: 400), latest: items)

        var grown = items
        grown[3] = bubbleItem("c", 12, 16)
        grown.insert(bubbleItem("late-system", 11, 13), at: 3)
        grown.append(bubbleItem("d", 16, 20))
        follower.itemsChanged(grown)

        #expect(follower.displayedItems(latest: grown) == items)
        #expect(follower.scrollRequest == nil)

        follower.returnToLive(latest: grown)

        #expect(follower.isFollowing)
        #expect(follower.displayedItems(latest: grown) == grown)
        #expect(follower.scrollRequest?.itemID == "d")
    }

    @Test("never mode does not follow or hold")
    func neverModeDoesNotHold() {
        let follower = FollowController(mode: .never)
        follower.scrollChanged(sample(offset: 800), latest: items)
        follower.scrollChanged(sample(offset: 100), latest: items)
        follower.itemsChanged(items + [bubbleItem("d", 15, 18)])

        #expect(!follower.isFollowing)
        #expect(follower.heldItems == nil)
        #expect(follower.scrollRequest == nil)

        follower.reveal(time: 13, latest: items)
        #expect(follower.scrollRequest?.itemID == "c")
        #expect(follower.heldItems == nil)
    }
}

/// A clock the test moves by hand.
@MainActor
private final class ManualClock {
    private(set) var now = ContinuousClock.now

    func advance(_ duration: Duration) {
        now += duration
    }
}
