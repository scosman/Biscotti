import DesignSystem
import SwiftUI

/// The live transcript over the bottom of the recording screen: the toggle at
/// the drawer's leading edge, and the drawer growing up from it, across most
/// of the window. The toggle never moves; the open drawer's footer reserves
/// its slot.
///
/// Chosen in UI review (25 October 2026): the drawer is wider than the notes
/// column, so bubbles are wide and short, and opening it moves the notes up
/// so the note field sits just above it, while the column's top, with Stop &
/// Save, stays in view (see `openLayout`). In the second review the user
/// added a height handle: the drawer's top edge drags to a height that is
/// remembered across meetings.
struct LiveTranscriptOverlay: View {
    /// The notes column's width limit.
    static let columnMaxWidth: CGFloat = 600
    /// The drawer's width limit.
    static let drawerMaxWidth: CGFloat = 880
    /// The space between the drawer and the window's sides and bottom.
    static let gutter: CGFloat = Tokens.spacingMD
    /// The space between the note field and the open drawer.
    static let noteFieldGap: CGFloat = Tokens.spacingMD
    /// The space kept above the column's top while the drawer is open.
    static let headerMargin: CGFloat = Tokens.spacingMD
    static let minimumDrawerHeight: CGFloat = 240
    /// How far one VoiceOver adjustment changes the height.
    static let heightStep: CGFloat = 40

    /// The open drawer's height and how far the notes scroll up for it.
    struct OpenLayout: Equatable {
        var drawerHeight: CGFloat
        var notesOffset: CGFloat
    }

    let viewModel: RecordingViewModel
    let drawerWidth: CGFloat
    let drawerHeight: CGFloat
    /// The tallest the drawer may be dragged to.
    let maximumHeight: CGFloat
    /// The height while the top edge is being dragged, nil otherwise.
    @Binding var dragHeight: CGFloat?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let isExpanded = viewModel.isDrawerExpanded
        ZStack(alignment: .bottomLeading) {
            if isExpanded {
                LiveTranscriptDrawer(viewModel: viewModel)
                    .frame(height: drawerHeight)
                    .overlay(alignment: .top) {
                        DrawerResizeHandle(
                            viewModel: viewModel,
                            height: drawerHeight,
                            maximumHeight: maximumHeight,
                            dragHeight: $dragHeight
                        )
                    }
                    .transition(drawerTransition)
            }
            // Where the open drawer's footer holds it, collapsed or not.
            LiveToggleButton(viewModel: viewModel)
                .padding(.leading, LiveTranscriptDrawer.outset)
        }
        .frame(width: drawerWidth, alignment: .bottomLeading)
        .padding(.bottom, Self.gutter)
        .animation(Self.motion(reduceMotion: reduceMotion), value: isExpanded)
    }

    /// Scales and fades from the toggle; a cross-fade with Reduce Motion.
    private var drawerTransition: AnyTransition {
        reduceMotion ? .opacity : .scale(scale: 0.2, anchor: .bottomLeading).combined(with: .opacity)
    }

    /// The drawer's motion, which the notes follow when they move.
    static func motion(reduceMotion: Bool) -> Animation {
        reduceMotion ? .easeInOut(duration: 0.15) : .spring(duration: 0.25)
    }

    /// Most of the window's width, at most 880 pt.
    static func drawerWidth(forAvailableWidth width: CGFloat) -> CGFloat {
        max(0, min(width - 2 * gutter, drawerMaxWidth))
    }

    /// 45% of the detail area, at least 240 pt and at most 520 pt.
    static func drawerHeight(forAvailableHeight height: CGFloat) -> CGFloat {
        min(max(height * 0.45, minimumDrawerHeight), 520)
    }

    /// The open drawer's height and the notes' scroll, so the column's top
    /// (the status row with Stop & Save, or the auto-stop card above it)
    /// stays in view. The drawer shrinks, to no less than 240 pt, until the
    /// column's top, the note field and the drawer fit; if they still do
    /// not, the column's top stays in view and the drawer covers the note field.
    ///
    /// - Parameters:
    ///   - headerTop: The top of the column's first row in the scroll
    ///     content, unscrolled.
    ///   - noteFieldBottom: The note field's bottom edge there.
    ///
    /// A height the user chose (`preferredHeight`) is kept between 240 pt
    /// and `maximumDrawerHeight`, which keeps the column's first rows (the
    /// status row with Stop & Save, and the auto-stop card) in view; a tall
    /// one may cover the note field.
    ///
    /// - Parameters:
    ///   - firstRowsHeight: From the column's top to the status row's bottom.
    static func openLayout(
        viewportHeight: CGFloat,
        headerTop: CGFloat,
        noteFieldBottom: CGFloat,
        firstRowsHeight: CGFloat = 0,
        preferredHeight: CGFloat? = nil
    ) -> OpenLayout {
        let height: CGFloat
        if let preferredHeight {
            height = clampedHeight(preferredHeight, viewportHeight: viewportHeight, firstRowsHeight: firstRowsHeight)
        } else {
            let header = max(0, noteFieldBottom - headerTop)
            let room = viewportHeight - headerMargin - header - noteFieldGap - gutter
            height = max(minimumDrawerHeight, min(drawerHeight(forAvailableHeight: viewportHeight), room))
        }
        let offset = notesOffset(noteFieldBottom: noteFieldBottom, viewportHeight: viewportHeight, drawerHeight: height)
        return OpenLayout(drawerHeight: height, notesOffset: min(offset, max(0, headerTop - headerMargin)))
    }

    /// The tallest drawer that leaves the column's first rows in view, with
    /// the column scrolled up to `headerMargin` from the top: never less
    /// than 240 pt.
    static func maximumDrawerHeight(viewportHeight: CGFloat, firstRowsHeight: CGFloat) -> CGFloat {
        max(minimumDrawerHeight, viewportHeight - gutter - noteFieldGap - firstRowsHeight - headerMargin)
    }

    static func clampedHeight(_ height: CGFloat, viewportHeight: CGFloat, firstRowsHeight: CGFloat) -> CGFloat {
        min(max(height, minimumDrawerHeight), maximumDrawerHeight(viewportHeight: viewportHeight, firstRowsHeight: firstRowsHeight))
    }

    /// The notes' bottom scroll margin, so the last note can scroll clear of
    /// the drawer or the toggle.
    static func notesBottomInset(showsLive: Bool, isExpanded: Bool, drawerHeight: CGFloat) -> CGFloat {
        guard showsLive else { return 0 }
        return isExpanded ? drawerHeight + gutter : 60
    }

    /// How far the notes scroll up while the drawer is open, so the note
    /// field's bottom sits `noteFieldGap` above the drawer; the header
    /// scrolls up with it. Zero when the note field already sits higher.
    ///
    /// - Parameter noteFieldBottom: The note field's bottom edge in the
    ///   scroll content, unscrolled.
    static func notesOffset(noteFieldBottom: CGFloat, viewportHeight: CGFloat, drawerHeight: CGFloat) -> CGFloat {
        let drawerTop = viewportHeight - gutter - drawerHeight
        return max(0, noteFieldBottom - (drawerTop - noteFieldGap))
    }
}

// MARK: - Height handle

/// The drawer's top edge: dragging it changes the height, double-clicking
/// restores the default, and VoiceOver adjusts it in 40 pt steps. A small
/// grabber shows while the pointer is over it.
private struct DrawerResizeHandle: View {
    static let hitHeight: CGFloat = 8

    let viewModel: RecordingViewModel
    let height: CGFloat
    let maximumHeight: CGFloat
    @Binding var dragHeight: CGFloat?
    @State private var isHovering = false
    @State private var startHeight: CGFloat?
    /// Resets on its own when a drag ends or is cancelled, for example when
    /// ⌘T hides the drawer mid-drag, which skips `onEnded`.
    @GestureState private var isDragging = false

    var body: some View {
        Color.clear
            .frame(maxWidth: .infinity)
            .frame(height: Self.hitHeight)
            .contentShape(Rectangle())
            .overlay(alignment: .top) {
                Capsule()
                    .fill(Color.inkTertiary)
                    .frame(width: 36, height: 4)
                    .padding(.top, 3)
                    .opacity(isHovering || dragHeight != nil ? 1 : 0)
                    .animation(.easeOut(duration: 0.12), value: isHovering)
            }
            .offset(y: -Self.hitHeight / 2)
            .pointerStyle(.frameResize(position: .top))
            .onHover { isHovering = $0 }
            .gesture(drag)
            .onChange(of: isDragging) { _, dragging in
                guard !dragging else { return }
                startHeight = nil
                dragHeight = nil
            }
            .onTapGesture(count: 2) { viewModel.resetLiveDrawerHeight() }
            .accessibilityElement()
            .accessibilityLabel("Transcript height")
            .accessibilityValue("\(Int(height.rounded())) points")
            .accessibilityHint("Drag to resize. Double-click to restore the default height.")
            .accessibilityAdjustableAction { direction in
                switch direction {
                case .increment: save(height + LiveTranscriptOverlay.heightStep)
                case .decrement: save(height - LiveTranscriptOverlay.heightStep)
                @unknown default: break
                }
            }
            .accessibilityAction(named: "Restore default height") { viewModel.resetLiveDrawerHeight() }
    }

    /// Dragging up makes the drawer taller.
    private var drag: some Gesture {
        DragGesture(minimumDistance: 1, coordinateSpace: .global)
            .updating($isDragging) { _, dragging, _ in dragging = true }
            .onChanged { value in
                let start = startHeight ?? height
                startHeight = start
                dragHeight = clamp(start - value.translation.height)
            }
            .onEnded { value in
                let start = startHeight ?? height
                startHeight = nil
                dragHeight = nil
                save(start - value.translation.height)
            }
    }

    private func clamp(_ value: CGFloat) -> CGFloat {
        min(max(value, LiveTranscriptOverlay.minimumDrawerHeight), maximumHeight)
    }

    private func save(_ value: CGFloat) {
        viewModel.setLiveDrawerHeight(clamp(value))
    }
}
