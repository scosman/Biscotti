import AppKit
import SwiftUI

/// Shared inline editable-title control used by both the meeting-detail
/// pane and the recording pane.
///
/// Behavior: click to edit, select all on focus, commit on Return or
/// click-away, tail-truncation when not editing, sage focus ring while
/// editing. The control owns its focus state and click-away monitor.
public struct EditableMeetingTitle: View {
    @Binding private var text: String

    /// Text shown in the display overlay when `text` is empty.
    private var placeholder: String

    /// Prompt shown inside the focused TextField when `text` is empty.
    /// Separate from `placeholder` so the focused prompt can differ
    /// (e.g. "Meeting title") from the display-mode placeholder
    /// (e.g. "Untitled meeting"), matching the original behavior.
    private var fieldPrompt: String

    private var font: Font
    private var tracking: CGFloat
    private var onCommit: () async -> Void

    @FocusState private var isFocused: Bool

    /// The title field's frame in SwiftUI global coordinates, captured
    /// via a `GeometryReader` background. Used by the click-away monitor
    /// to distinguish inside vs outside clicks.
    @State private var titleFrame: CGRect = .zero

    /// Local event monitor that resigns the title field when the user
    /// clicks outside its bounds. Installed while `isFocused` is true;
    /// removed on unfocus and `onDisappear`.
    @State private var clickAwayMonitor: Any?

    public init(
        text: Binding<String>,
        placeholder: String,
        fieldPrompt: String = "",
        font: Font,
        tracking: CGFloat = -0.27,
        onCommit: @escaping () async -> Void
    ) {
        _text = text
        self.placeholder = placeholder
        self.fieldPrompt = fieldPrompt.isEmpty ? placeholder : fieldPrompt
        self.font = font
        self.tracking = tracking
        self.onCommit = onCommit
    }

    public var body: some View {
        ZStack(alignment: .leading) {
            // ALWAYS present -- hidden text when not editing
            TextField(
                isFocused ? fieldPrompt : "",
                text: $text
            )
            .font(font)
            .tracking(tracking)
            .foregroundStyle(
                isFocused ? Color.ink : Color.clear
            )
            .textFieldStyle(.plain)
            .focused($isFocused)
            .onSubmit {
                isFocused = false
                Task { await onCommit() }
            }

            // Truncating display + tap-to-edit (non-edit only)
            if !isFocused {
                Text(
                    text.isEmpty
                        ? placeholder
                        : text
                )
                .font(font)
                .tracking(tracking)
                .foregroundStyle(
                    text.isEmpty
                        ? .inkTertiary : .ink
                )
                .lineLimit(1)
                .truncationMode(.tail)
                .frame(
                    maxWidth: .infinity,
                    alignment: .leading
                )
                .contentShape(Rectangle())
                .onTapGesture {
                    isFocused = true
                    DispatchQueue.main.async {
                        NSApp.sendAction(
                            #selector(
                                NSResponder.selectAll(_:)
                            ),
                            to: nil,
                            from: nil
                        )
                    }
                }
            }
        }
        // Focused styling: white fill + sage outline that bleeds
        // outward so the text position and sibling layout stay
        // fixed. Transparent when not focused -> no visible box.
        .padding(.top, 7)
        .padding(.bottom, 3)
        .padding(.horizontal, 6)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(
                    isFocused
                        ? Color.white : Color.clear
                )
        )
        .overlay(
            RoundedRectangle(cornerRadius: 6)
                .strokeBorder(
                    isFocused
                        ? Color.sage : Color.clear,
                    lineWidth: 2
                )
        )
        .padding(.top, -7)
        .padding(.bottom, -3)
        .padding(.horizontal, -6)
        // Capture frame for click-away monitor. On the outer
        // ZStack so titleFrame is valid in edit mode.
        .background(
            GeometryReader { proxy in
                Color.clear
                    .onAppear {
                        titleFrame = proxy.frame(
                            in: .global
                        )
                    }
                    .onChange(
                        of: proxy.frame(in: .global)
                    ) { _, newFrame in
                        titleFrame = newFrame
                    }
            }
        )
        // Click-away monitor lifecycle: install on focus, remove on blur.
        .onChange(of: isFocused) { _, focused in
            if focused {
                installClickAwayMonitor()
            } else {
                removeClickAwayMonitor()
            }
        }
        .onDisappear {
            isFocused = false
            removeClickAwayMonitor()
        }
    }

    // MARK: - Click-away monitor helpers

    /// Installs a local event monitor that resigns the title field when
    /// the user clicks outside its bounds. The event is always returned
    /// (never consumed) so the click reaches its intended target.
    ///
    /// Coordinate conversion: `event.locationInWindow` is in AppKit's
    /// bottom-left-origin system. We flip it to SwiftUI's top-left-origin
    /// global coordinates using the window content view's height, then
    /// hit-test against `titleFrame` (captured in `.global` coordinates
    /// via a `GeometryReader` background on the title field).
    ///
    /// No capture list: the closure reads `self.titleFrame` live each
    /// invocation so it tracks window resizes / scroll / sidebar toggles.
    private func installClickAwayMonitor() {
        removeClickAwayMonitor()
        clickAwayMonitor = NSEvent.addLocalMonitorForEvents(
            matching: [.leftMouseDown]
        ) { event in
            guard let contentView = event.window?.contentView else {
                return event
            }
            let loc = event.locationInWindow
            // Flip y: AppKit bottom-left -> SwiftUI top-left.
            let flipped = CGPoint(
                x: loc.x,
                y: contentView.bounds.height - loc.y
            )
            if !titleFrame.contains(flipped) {
                // Explicit MainActor hop: local monitors fire on main
                // in practice but it's not formally guaranteed.
                Task { @MainActor in
                    isFocused = false
                    await onCommit()
                }
            }
            return event
        }
    }

    /// Removes the click-away monitor if installed.
    private func removeClickAwayMonitor() {
        if let monitor = clickAwayMonitor {
            NSEvent.removeMonitor(monitor)
            clickAwayMonitor = nil
        }
    }
}

#Preview("EditableMeetingTitle") {
    struct PreviewWrapper: View {
        @State private var title = "Weekly Standup"
        var body: some View {
            VStack(alignment: .leading, spacing: 20) {
                EditableMeetingTitle(
                    text: $title,
                    placeholder: "Untitled meeting",
                    font: .biscottiSerif(27)
                ) {}

                EditableMeetingTitle(
                    text: .constant(""),
                    placeholder: "Untitled recording",
                    font: .biscottiSerif(26)
                ) {}
            }
            .padding()
            .frame(width: 400)
            .background(Tokens.contentBackground)
        }
    }
    return PreviewWrapper()
}
