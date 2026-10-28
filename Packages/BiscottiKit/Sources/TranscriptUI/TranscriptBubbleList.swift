import AppKit
import DesignSystem
import SwiftUI

/// The bubble transcript, shared by the live drawer and every meeting's
/// Transcript tab.
///
/// **Performance:** built on `List` so only visible rows are materialized.
/// `ForEach(items)` stays a direct child of
/// the `List`, and each row is wrapped in `.equatable()` keyed on its own
/// item, highlights and `canSeek`, so a 4 Hz playback tick or a live tail
/// update re-renders only the rows that changed.
///
/// **`header` is never behind an equality guard.** It carries page chrome
/// owned by the caller (title, tabs, the Copy button's "Copied" feedback),
/// which must re-render whenever it changes.
///
/// **Following** (`.live`): the list follows new items while scrolled to the
/// bottom; scrolling up holds the items on screen still until Return to live
/// or scrolling back down. See ``FollowController``.
public struct TranscriptBubbleList<Header: View>: View {
    private let items: [TranscriptItem]
    private let canSeek: Bool
    private let follow: FollowMode
    private let find: FindState?
    @Binding private var revealTime: TimeInterval?
    @Binding private var anchorTime: TimeInterval?
    private let onSeek: (TimeInterval) -> Void
    private let onSpeaker: (Int) -> Void
    private let onSpeakerDebug: ((Int) -> Void)?
    private let onFocusChange: ((Bool) -> Void)?
    private let rowPadding: CGFloat
    private let maxRowWidth: CGFloat
    private let bottomPadding: CGFloat
    private let showsHeader: Bool
    private let header: Header

    /// Created once, on first use: an initial value here would be built on
    /// every parent re-render (about 4 Hz during playback) and thrown away.
    @State private var state: ListState?

    /// - Parameters:
    ///   - items: The items to show, from ``TranscriptItemBuilder``.
    ///   - canSeek: Whether times and play buttons seek the audio player.
    ///   - follow: `.never` for saved transcripts and drafts, `.live` for the drawer.
    ///   - find: The drawer's find state; its matches are highlighted.
    ///   - revealTime: Scrolls once to the item holding this time, then is set to nil.
    ///   - anchorTime: Reports the start time of the topmost visible item, or
    ///     nil while the header is visible. Used to keep the reader's place
    ///     across a draft-to-final swap.
    ///   - onSeek: Called with a time when a time or play button is clicked.
    ///   - onSpeaker: Called with a speaker ID when a speaker name is clicked.
    ///   - onSpeakerDebug: Adds the DEBUG "Voiceprint Debug…" menu to speaker names.
    ///   - onFocusChange: Reports whether text is selected in a bubble of
    ///     this list. A selection in the header does not count.
    ///   - rowPadding: The space on each side of the rows.
    ///   - maxRowWidth: The rows' width limit, padding included: the page's
    ///     readable width, or `.infinity` where the container already limits it.
    ///   - bottomPadding: Extra space below the last row.
    ///   - header: Page chrome shown as the first, non-recycled row.
    public init(
        items: [TranscriptItem],
        canSeek: Bool,
        follow: FollowMode,
        find: FindState? = nil,
        revealTime: Binding<TimeInterval?> = .constant(nil),
        anchorTime: Binding<TimeInterval?> = .constant(nil),
        onSeek: @escaping (TimeInterval) -> Void,
        onSpeaker: @escaping (Int) -> Void,
        onSpeakerDebug: ((Int) -> Void)? = nil,
        onFocusChange: ((Bool) -> Void)? = nil,
        rowPadding: CGFloat = Tokens.homeHorizontalPadding,
        maxRowWidth: CGFloat = Tokens.readableContentMaxWidth,
        bottomPadding: CGFloat = 0,
        @ViewBuilder header: () -> Header
    ) {
        self.items = items
        self.canSeek = canSeek
        self.follow = follow
        self.find = find
        _revealTime = revealTime
        _anchorTime = anchorTime
        self.onSeek = onSeek
        self.onSpeaker = onSpeaker
        self.onSpeakerDebug = onSpeakerDebug
        self.onFocusChange = onFocusChange
        self.rowPadding = rowPadding
        self.maxRowWidth = maxRowWidth
        self.bottomPadding = bottomPadding
        showsHeader = Header.self != EmptyView.self
        self.header = header()
    }

    public var body: some View {
        let follower = state?.follower
        let shown = follower?.displayedItems(latest: items) ?? items
        ScrollViewReader { proxy in
            List {
                if showsHeader {
                    header
                        .readableRowWidth(padding: rowPadding, maxWidth: maxRowWidth)
                        .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { height in
                            listState().tracker.updateHeader(height: height)
                            publishAnchor()
                        }
                        .listRowSeparator(.hidden)
                        .listRowBackground(Color.clear)
                        .listRowInsets(EdgeInsets())
                }

                ForEach(shown) { item in
                    TranscriptItemRow(
                        item: item,
                        highlights: find?.highlights(for: item.id) ?? .none,
                        canSeek: canSeek,
                        onSeek: onSeek,
                        onSpeaker: onSpeaker,
                        onSpeakerDebug: onSpeakerDebug
                    )
                    .equatable()
                    .padding(.top, Self.topSpacing(for: item))
                    .padding(.bottom, item.id == shown.last?.id ? bottomPadding : 0)
                    .readableRowWidth(padding: rowPadding, maxWidth: maxRowWidth)
                    .onGeometryChange(for: CGRect.self) { $0.frame(in: .scrollView) } action: { frame in
                        listState().tracker.update(id: item.id, startTime: item.startTime, frame: frame)
                        publishAnchor()
                    }
                    .onDisappear { state?.tracker.remove(id: item.id) }
                    .listRowSeparator(.hidden)
                    .listRowBackground(Color.clear)
                    // A macOS `List` applies a row's top inset above and below
                    // the row and ignores the bottom inset, so rows have no
                    // vertical insets and space themselves with top padding.
                    .listRowInsets(EdgeInsets())
                }
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
            .onScrollGeometryChange(for: ScrollSample.self) { geometry in
                ScrollSample(
                    offsetY: geometry.contentOffset.y,
                    contentHeight: geometry.contentSize.height,
                    containerHeight: geometry.containerSize.height,
                    insetTop: geometry.contentInsets.top
                )
            } action: { _, sample in
                let state = listState()
                state.follower.scrollChanged(sample, latest: items)
                state.tracker.updateScroll(offsetY: sample.offsetY, insetTop: sample.insetTop)
                publishAnchor()
            }
            .overlay(alignment: .bottom) { returnToLive }
            .background {
                if let onFocusChange {
                    TranscriptFocusProbe(hasHeaderRow: showsHeader, onChange: onFocusChange)
                }
            }
            .onChange(of: follower?.scrollRequest) { _, request in
                guard let request else { return }
                proxy.scrollTo(request.itemID, anchor: request.anchor.unitPoint)
                follower?.consumeScrollRequest()
            }
            .onChange(of: items) { _, latest in
                follower?.itemsChanged(latest)
            }
            .onChange(of: follow) { _, mode in
                state = ListState(mode: mode)
            }
            .onChange(of: shown) { _, shown in
                find?.update(items: shown)
            }
            .onChange(of: find?.isOpen ?? false) { _, isOpen in
                if isOpen {
                    listState().follower.findOpened(latest: items)
                } else {
                    listState().follower.findClosed(latest: items)
                }
            }
            // The match, not only its index: a new query whose first match
            // is elsewhere keeps index 0.
            .onChange(of: find?.currentMatch) { _, match in
                if let match {
                    listState().follower.scroll(to: match.itemID, anchor: .center)
                }
            }
            .onChange(of: revealTime) { _, _ in
                applyReveal()
            }
            .task {
                find?.update(items: shown)
                // Let the list lay out its rows before scrolling.
                await Task.yield()
                // A following list opens at the newest item.
                listState().follower.itemsChanged(items)
                applyReveal()
            }
        }
    }

    /// Hidden while find is open: following resumes only once find closes.
    private var returnToLive: some View {
        let isFollowing = state?.follower.isFollowing ?? true
        let isFindOpen = find?.isOpen ?? false
        return ZStack {
            if follow == .live, !isFollowing, !isFindOpen {
                ReturnToLiveButton {
                    listState().follower.returnToLive(latest: items)
                }
                .padding(.bottom, Tokens.spacingSM + Tokens.spacingXS)
                .transition(.opacity)
            }
        }
        .animation(.easeInOut(duration: 0.2), value: isFollowing)
    }

    /// The list's state, created on first use. Called only from actions,
    /// never from `body`.
    private func listState() -> ListState {
        if let state { return state }
        let created = ListState(mode: follow)
        state = created
        return created
    }

    private func applyReveal() {
        guard let time = revealTime else { return }
        listState().follower.reveal(time: time, latest: items)
        revealTime = nil
    }

    private func publishAnchor() {
        let top = state?.tracker.topVisibleStartTime
        if anchorTime != top { anchorTime = top }
    }

    /// The space above a row (ui_design.md): 12 pt above the first bubble of
    /// a run and above markers, 4 pt between bubbles of one run. The run
    /// label adds its own 4 pt above the bubble.
    static func topSpacing(for item: TranscriptItem) -> CGFloat {
        switch item.kind {
        case let .bubble(bubble): bubble.startsRun ? 12 : Tokens.spacingXS
        case .gap, .startMarker: 12
        }
    }
}

/// Following and the visible-row tracker, owned by one list.
@MainActor
final class ListState {
    let follower: FollowController
    let tracker = VisibleRowTracker()

    /// Created when the list appears (or its follow mode changes), so the
    /// list's first layout passes do not stop following.
    init(mode: FollowMode) {
        follower = FollowController(mode: mode)
        follower.listAppeared()
    }
}

public extension TranscriptBubbleList where Header == EmptyView {
    /// A list without page chrome: the drawer, whose header sits above it.
    init(
        items: [TranscriptItem],
        canSeek: Bool,
        follow: FollowMode,
        find: FindState? = nil,
        revealTime: Binding<TimeInterval?> = .constant(nil),
        onSeek: @escaping (TimeInterval) -> Void = { _ in },
        onSpeaker: @escaping (Int) -> Void = { _ in },
        rowPadding: CGFloat,
        maxRowWidth: CGFloat = Tokens.readableContentMaxWidth,
        bottomPadding: CGFloat = 0
    ) {
        self.init(
            items: items,
            canSeek: canSeek,
            follow: follow,
            find: find,
            revealTime: revealTime,
            onSeek: onSeek,
            onSpeaker: onSpeaker,
            rowPadding: rowPadding,
            maxRowWidth: maxRowWidth,
            bottomPadding: bottomPadding
        ) { EmptyView() }
    }
}

// MARK: - Return to live

/// The capsule shown above the drawer footer while reading back.
struct ReturnToLiveButton: View {
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Label("Return to live", systemImage: "arrow.down")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.ink)
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(
                    Capsule()
                        .fill(Tokens.elevatedFill)
                        .shadow(color: Tokens.controlShadow, radius: 4, y: 1)
                )
                // A hairline keeps the white capsule visible on the drawer's
                // white card.
                .overlay(Capsule().strokeBorder(Tokens.cardStroke, lineWidth: 0.5))
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Row width

extension View {
    /// Caps content at the page's readable width with horizontal padding,
    /// centered in the full row, so the `List` (and its scroller) can span
    /// the whole pane.
    func readableRowWidth(
        padding horizontalPadding: CGFloat = Tokens.homeHorizontalPadding,
        maxWidth: CGFloat = Tokens.readableContentMaxWidth
    ) -> some View {
        padding(.horizontal, horizontalPadding)
            .frame(maxWidth: maxWidth, alignment: .leading)
            .frame(maxWidth: .infinity)
    }
}

// MARK: - Focus probe

/// Reports whether text is selected in a bubble of the list: the window's
/// first responder is a non-editable text view with a non-empty selection,
/// in one of the list's item rows. A selectable `Text` selects through a
/// field editor that is not editable; the title field edits through an
/// editable one. The header (the page chrome, including the calendar card's
/// selectable text) is the list's row 0, so a selection there does not count.
///
/// It sits in the list's background, so the list's `NSScrollView` is not
/// one of its ancestors; it finds the scroll view that overlaps it in an
/// ancestor's subtree. The `List` spike showed that selecting text in a
/// bubble makes an `NSTextView` inside that scroll view first responder,
/// and that KVO on `NSWindow.firstResponder` reports each change; selection
/// changes come from `NSTextView.didChangeSelectionNotification`.
struct TranscriptFocusProbe: NSViewRepresentable {
    /// Whether row 0 is the header; without one, row 0 is a bubble.
    let hasHeaderRow: Bool
    let onChange: (Bool) -> Void

    func makeNSView(context _: Context) -> FocusProbeView {
        let view = FocusProbeView()
        view.hasHeaderRow = hasHeaderRow
        view.onChange = onChange
        return view
    }

    func updateNSView(_ view: FocusProbeView, context _: Context) {
        view.hasHeaderRow = hasHeaderRow
        view.onChange = onChange
    }

    static func dismantleNSView(_ view: FocusProbeView, coordinator _: ()) {
        view.stopObserving()
    }
}

final class FocusProbeView: NSView {
    var onChange: ((Bool) -> Void)?
    var hasHeaderRow = true
    private var observation: NSKeyValueObservation?
    private var lastReported: Bool?
    private var pendingRelease: Task<Void, Never>?

    /// How long a lost selection must stay lost before it is reported. A
    /// drag briefly empties the selection as the field editor moves.
    static let releaseDelay: Duration = .milliseconds(300)

    override func hitTest(_: NSPoint) -> NSView? {
        nil
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        NotificationCenter.default.removeObserver(self, name: NSTextView.didChangeSelectionNotification, object: nil)
        observation = window?.observe(\.firstResponder, options: [.initial, .new]) { [weak self] _, _ in
            MainActor.assumeIsolated { self?.evaluate() }
        }
        if window == nil {
            pendingRelease?.cancel()
            send(false)
        } else {
            NotificationCenter.default.addObserver(
                self,
                selector: #selector(selectionDidChange),
                name: NSTextView.didChangeSelectionNotification,
                object: nil
            )
        }
    }

    func stopObserving() {
        observation = nil
        NotificationCenter.default.removeObserver(self, name: NSTextView.didChangeSelectionNotification, object: nil)
        pendingRelease?.cancel()
        send(false)
    }

    @objc private func selectionDidChange(_ notification: Notification) {
        guard notification.object as? NSTextView === window?.firstResponder else { return }
        evaluate()
    }

    private func evaluate() {
        guard let textView = window?.firstResponder as? NSTextView,
              !textView.isEditable,
              textView.selectedRange().length > 0,
              let scrollView = listScrollView()
        else {
            report(false)
            return
        }
        guard textView.isDescendant(of: scrollView) else {
            report(false)
            return
        }
        // The `List` is an NSTableView (the spike). If a later SwiftUI stops
        // using one, any selection in the list counts.
        guard let table = scrollView.documentView as? NSTableView else {
            report(true)
            return
        }
        report(Self.rowHoldsBubble(table.row(for: textView), hasHeaderRow: hasHeaderRow))
    }

    /// Only the header's row (0, when there is a header) is ruled out. A text
    /// view the table cannot place in a row (-1) counts, like any selection in
    /// a list that is not a table: when unsure, the swap waits.
    static func rowHoldsBubble(_ row: Int, hasHeaderRow: Bool) -> Bool {
        !(hasHeaderRow && row == 0)
    }

    /// A selection is reported at once; its loss only once it has lasted
    /// ``releaseDelay``, so a drag that briefly empties the selection does
    /// not let a waiting swap through.
    private func report(_ focused: Bool) {
        if focused {
            pendingRelease?.cancel()
            pendingRelease = nil
            send(true)
        } else if lastReported == true {
            guard pendingRelease == nil else { return }
            pendingRelease = Task { [weak self] in
                try? await Task.sleep(for: Self.releaseDelay)
                guard !Task.isCancelled else { return }
                self?.pendingRelease = nil
                self?.send(false)
            }
        } else {
            send(false)
        }
    }

    /// Reported on the next run-loop turn: KVO and dismantling can happen
    /// during a SwiftUI update, which must not change observed state.
    private func send(_ focused: Bool) {
        guard focused != lastReported else { return }
        lastReported = focused
        let onChange = onChange
        DispatchQueue.main.async { onChange?(focused) }
    }

    private func listScrollView() -> NSScrollView? {
        let frame = convert(bounds, to: nil)
        var ancestor = superview
        while let current = ancestor {
            if let found = Self.scrollView(in: current, overlapping: frame) { return found }
            ancestor = current.superview
        }
        return nil
    }

    private static func scrollView(in view: NSView, overlapping frame: NSRect) -> NSScrollView? {
        for subview in view.subviews {
            if let scrollView = subview as? NSScrollView,
               scrollView.convert(scrollView.bounds, to: nil).intersects(frame)
            {
                return scrollView
            }
            if let found = scrollView(in: subview, overlapping: frame) { return found }
        }
        return nil
    }
}
