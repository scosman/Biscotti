import Foundation
import Observation
import os
import SwiftUI

/// The parts of the list's scroll geometry that following and the visible-row tracker need.
public struct ScrollSample: Equatable, Sendable {
    /// How close to the end of the content still counts as "at the bottom".
    public static let bottomTolerance: CGFloat = 24

    public var offsetY: CGFloat
    public var contentHeight: CGFloat
    public var containerHeight: CGFloat
    /// The top content inset: the part of the scroll view under a toolbar.
    /// At rest at the top, `offsetY` is `-insetTop`.
    public var insetTop: CGFloat

    public init(offsetY: CGFloat, contentHeight: CGFloat, containerHeight: CGFloat, insetTop: CGFloat = 0) {
        self.offsetY = offsetY
        self.contentHeight = contentHeight
        self.containerHeight = containerHeight
        self.insetTop = insetTop
    }

    public var isAtBottom: Bool {
        offsetY + containerHeight >= contentHeight - Self.bottomTolerance
    }
}

/// A scroll the list should perform once.
public struct ScrollRequest: Equatable, Sendable {
    public enum Anchor: Equatable, Sendable {
        case top
        case center
        case bottom

        var unitPoint: UnitPoint {
            switch self {
            case .top: .top
            case .center: .center
            case .bottom: .bottom
            }
        }
    }

    public var itemID: String
    public var anchor: Anchor
    /// Distinguishes two requests for the same item.
    public var token: Int
}

/// Following, reading back and reveal for the bubble list. Pure state, no views.
///
/// While following, the list shows the newest items and scrolls to the bottom
/// on each update. When following stops (the user scrolls up, opens find or a
/// time is revealed), the list keeps showing the items it had, so nothing on
/// screen moves; ``returnToLive(latest:)`` or scrolling back to the bottom
/// applies everything that arrived meanwhile.
@MainActor @Observable
public final class FollowController {
    /// How long after the list appears a scroll away from the bottom is the
    /// list laying out its rows, not the reader: a reopened drawer landed at
    /// its first row and stopped following (hardware review, 25 October 2026).
    public static let appearanceSettle: Duration = .seconds(1)

    private static let log = Logger(subsystem: "net.scosman.biscotti", category: "live")

    public let mode: FollowMode
    public private(set) var isFollowing: Bool
    /// The items on screen while reading back; nil while following.
    public private(set) var heldItems: [TranscriptItem]?
    public private(set) var scrollRequest: ScrollRequest?

    @ObservationIgnored private var lastSample: ScrollSample?
    @ObservationIgnored private var isFindOpen = false
    /// Find opened while following: closing it returns to live.
    @ObservationIgnored private var followsAfterFind = false
    @ObservationIgnored private var settlesUntil: ContinuousClock.Instant?
    @ObservationIgnored private var nextToken = 0
    @ObservationIgnored private let now: () -> ContinuousClock.Instant

    public init(mode: FollowMode, now: @escaping () -> ContinuousClock.Instant = { .now }) {
        self.mode = mode
        self.now = now
        isFollowing = mode == .live
    }

    /// The list appeared and starts laying out its rows, for example when the
    /// drawer opens again: for `appearanceSettle`, a following list that
    /// lands away from the bottom scrolls to the newest item again instead of
    /// stopping.
    public func listAppeared() {
        settlesUntil = now() + Self.appearanceSettle
    }

    private var isSettling: Bool {
        settlesUntil.map { now() < $0 } ?? false
    }

    /// What the list shows: the held items while reading back, else the latest.
    public func displayedItems(latest: [TranscriptItem]) -> [TranscriptItem] {
        heldItems ?? latest
    }

    /// New items arrived. While following, scroll to the newest one.
    public func itemsChanged(_ latest: [TranscriptItem]) {
        guard mode == .live, isFollowing, let newest = latest.last else { return }
        request(newest.id, .bottom)
    }

    /// The list scrolled or its content changed size.
    ///
    /// Reaching the bottom resumes following (unless find is open). Leaving
    /// it stops following only when the offset moved up: content that grows
    /// under a following list also leaves it short of the bottom until the
    /// next scroll to the newest item, and that must not stop following.
    public func scrollChanged(_ sample: ScrollSample, latest: [TranscriptItem]) {
        let previous = lastSample
        lastSample = sample
        guard mode == .live else { return }

        if sample.isAtBottom {
            if !isFollowing, !isFindOpen { resumeFollowing(latest) }
            return
        }
        guard isFollowing else { return }
        if isSettling {
            if scrollRequest == nil, let newest = latest.last { request(newest.id, .bottom) }
            return
        }
        if let previous, sample.offsetY < previous.offsetY {
            Self.log.notice("The transcript stopped following: scrolled up from \(previous.offsetY, privacy: .public) to \(sample.offsetY, privacy: .public) of \(sample.contentHeight, privacy: .public) pt in a \(sample.containerHeight, privacy: .public) pt view")
            stopFollowing(latest)
        }
    }

    /// The Return to live button.
    public func returnToLive(latest: [TranscriptItem]) {
        guard mode == .live else { return }
        resumeFollowing(latest)
    }

    public func findOpened(latest: [TranscriptItem]) {
        isFindOpen = true
        followsAfterFind = isFollowing
        if isFollowing { stopFollowing(latest) }
    }

    /// Closing find returns to live when the list followed before find
    /// opened, or is at the bottom: find only pauses following (functional
    /// spec, "Search"). A reader who was reading back stays where they are.
    public func findClosed(latest: [TranscriptItem]) {
        isFindOpen = false
        defer { followsAfterFind = false }
        guard mode == .live, !isFollowing else { return }
        if followsAfterFind || lastSample?.isAtBottom == true {
            resumeFollowing(latest)
        }
    }

    /// Scrolls to the item that holds `time` and stops following, also
    /// after find closes. A reader already reading back may ask for a time
    /// past the items held on screen, so the held items catch up with the
    /// latest first; the list stays reading back at the target.
    public func reveal(time: TimeInterval, latest: [TranscriptItem]) {
        followsAfterFind = false
        if mode == .live { stopFollowing(latest) }
        guard let target = Self.revealTarget(for: time, in: displayedItems(latest: latest)) else { return }
        request(target, .top)
    }

    /// Scrolls to an item, for example the current find match.
    public func scroll(to itemID: String, anchor: ScrollRequest.Anchor) {
        request(itemID, anchor)
    }

    /// The list performed the request.
    public func consumeScrollRequest() {
        scrollRequest = nil
    }

    /// The gap marker whose gap contains `time`, else the first item whose
    /// time range contains it, else the nearest item that starts before it,
    /// else the first item.
    public static func revealTarget(for time: TimeInterval, in items: [TranscriptItem]) -> String? {
        let containing = items.filter { $0.timeRange.contains(time) }
        if let target = containing.first(where: { $0.bubble == nil }) ?? containing.first {
            return target.id
        }
        return (items.last { $0.startTime <= time } ?? items.first)?.id
    }

    private func stopFollowing(_ latest: [TranscriptItem]) {
        isFollowing = false
        heldItems = latest
    }

    private func resumeFollowing(_ latest: [TranscriptItem]) {
        isFollowing = true
        heldItems = nil
        if let newest = latest.last { request(newest.id, .bottom) }
    }

    private func request(_ itemID: String, _ anchor: ScrollRequest.Anchor) {
        nextToken += 1
        scrollRequest = ScrollRequest(itemID: itemID, anchor: anchor, token: nextToken)
    }
}
