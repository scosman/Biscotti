import AppCore
import AppKit
import DataStore
import DesignSystem
import MarkdownEditorUI
import SwiftUI
import TranscriptionService

/// The Meeting Detail screen showing metadata, transcript, calendar
/// context, audio playback, notes, and status.
///
/// Layout: while loading, shows a centered spinner. Once loaded, a
/// single outer `ScrollView` containing a chrome section (header,
/// calendar card, tab bar) measured via a preference key, and a
/// tab-content area sized to fill the remaining viewport. The audio
/// transport bar is pinned to the bottom of the panel via
/// `safeAreaInset`, staying fixed regardless of scroll position.
/// The Notes editor scrolls internally; the Transcript tab grows
/// with content and the outer scroll handles it.
public struct MeetingDetailView: View {
    @Bindable private var viewModel: MeetingDetailViewModel

    /// Measured height of the chrome section (header + calendar + tabs).
    @State private var chromeHeight: CGFloat = 0

    /// Measured height of the pinned transport bar at the bottom.
    @State private var transportHeight: CGFloat = 0

    /// Transient "Copied" feedback: true for ~1.5s after a copy action.
    @State private var didCopy = false

    /// Cancellable timer that reverts `didCopy` after the feedback window.
    /// Stored so rapid re-clicks restart the window cleanly.
    @State private var copyResetTask: Task<Void, Never>?

    public init(viewModel: MeetingDetailViewModel) {
        self.viewModel = viewModel
    }

    public var body: some View {
        GeometryReader { geo in
            if viewModel.isLoading {
                // B: unified loading state — one centered spinner for the
                // whole detail pane while the meeting data loads.
                VStack {
                    Spacer()
                    ProgressView("Loading\u{2026}")
                    Spacer()
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                loadedContent(geo: geo)
            }
        }
        .background(Tokens.contentBackground)
        .frame(
            maxWidth: .infinity,
            maxHeight: .infinity,
            alignment: .topLeading
        )
        .task { await viewModel.load() }
        .task { await viewModel.applyPendingJumpIfNeeded() }
        .onChange(of: viewModel.currentJobStatus) { _, newStatus in
            Task { await viewModel.onJobStatusChange(newStatus) }
        }
        .onChange(of: viewModel.pendingJumpToken) { _, _ in
            Task { await viewModel.applyPendingJumpIfNeeded() }
        }
        .onChange(of: viewModel.selectedTab) { _, _ in
            // Clear stale "Copied" feedback when switching tabs.
            copyResetTask?.cancel()
            copyResetTask = nil
            didCopy = false
        }
        .onDisappear {
            copyResetTask?.cancel()
            copyResetTask = nil
            Task { await viewModel.flushNotes() }
        }
        .sheet(isPresented: $viewModel.showEventPicker) {
            EventPickerSheet(
                events: viewModel.availableEventPickerItems,
                hasCalendarAccess: viewModel.hasCalendarAccess,
                hasExistingAssociation: viewModel.hasCalendarContext,
                onSelect: { eventKey in
                    Task {
                        await viewModel.correctAssociation(
                            eventKey: eventKey
                        )
                    }
                },
                onRemove: {
                    Task {
                        await viewModel.removeAssociation()
                    }
                },
                onCancel: {
                    viewModel.showEventPicker = false
                }
            )
        }
        .confirmationDialog(
            "Delete this meeting?",
            isPresented: $viewModel.showDeleteConfirmation,
            titleVisibility: .visible
        ) {
            Button("Delete", role: .destructive) {
                Task { await viewModel.confirmDelete() }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(
                "This permanently deletes the recording and transcript."
            )
        }
    }

    // MARK: - Loaded content

    /// The main content shown after the initial data load completes.
    /// Extracted from `body` to keep each function under the line limit.
    ///
    /// The ScrollView fills the full pane width (scrollbar at the
    /// window's right edge). Inside, the readable content is capped at
    /// `Tokens.readableContentMaxWidth` and left-aligned, with whitespace
    /// filling the right.
    ///
    /// The `AudioTransport` is pinned to the bottom of the panel via
    /// `safeAreaInset(edge: .bottom)`, which automatically adjusts the
    /// scroll content inset and scroll indicator so the last line of
    /// content is never hidden behind the bar.
    private func loadedContent(geo: GeometryProxy) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                chrome

                Divider()
                    .padding(.vertical, Tokens.spacingMD)

                tabContent(fill: max(250, contentFill(viewportHeight: geo.size.height)))
            }
            .padding(.horizontal, Tokens.homeHorizontalPadding)
            .padding(.top, Tokens.homeVerticalPadding)
            .padding(.bottom, Tokens.homeVerticalPadding)
            .frame(maxWidth: Tokens.readableContentMaxWidth, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .onPreferenceChange(ChromeHeightKey.self) { chromeHeight = $0 }
        .onPreferenceChange(TransportHeightKey.self) { transportHeight = $0 }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            pinnedTransportBar
        }
    }

    /// Height available for tab content after subtracting chrome, padding,
    /// and the pinned transport bar.
    ///
    /// The caller applies a 250pt floor via `max(250, contentFill(...))` so
    /// the notes editor stays usable in small windows. In normal/large
    /// windows the exact fill exceeds 250 and the floor does not bind,
    /// preserving the single-scroll-region behavior.
    ///
    /// **Layout coupling:** the `verticalOverhead` constant mirrors the
    /// padding and divider in `loadedContent(geo:)`. If you change the
    /// padding values or divider there, update this calculation to match.
    /// The `transportHeight` is measured via `TransportHeightKey` in
    /// `pinnedTransportBar` — it accounts for the bottom `safeAreaInset`
    /// that the outer `GeometryReader` does not subtract from its reported
    /// size.
    private func contentFill(viewportHeight: CGFloat) -> CGFloat {
        let verticalOverhead =
            Tokens.homeVerticalPadding * 2 // top + bottom page padding
            + Tokens.spacingMD * 2 // divider vertical padding
            + 1 // divider pixel height
        return max(0, viewportHeight - chromeHeight - transportHeight - verticalOverhead)
    }

    // MARK: - Header

    private var header: some View {
        VStack(alignment: .leading, spacing: Tokens.spacingXS) {
            HStack(alignment: .top) {
                EditableMeetingTitle(
                    text: $viewModel.editableTitle,
                    placeholder: "Untitled meeting",
                    fieldPrompt: "Meeting title",
                    font: .biscottiSerif(27)
                ) {
                    await viewModel.saveTitle()
                }

                Spacer()

                overflowMenu
            }

            metaLine
        }
    }

    private static let versionDateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter
    }()

    /// Whether copy is possible for the active tab. Non-mutating: uses
    /// `hasDisplayableTranscript` instead of calling the cache-building
    /// method, so it is safe during `body` evaluation.
    private var canCopy: Bool {
        switch viewModel.selectedTab {
        case .transcript:
            viewModel.hasDisplayableTranscript
        case .notes:
            !viewModel.notes.isEmpty
        }
    }
}

// MARK: - Chrome sub-views

private extension MeetingDetailView {
    /// Audio transport pinned to the bottom of the panel. Full-width
    /// background (Liquid Glass on macOS 26+, vibrancy material on older);
    /// inner content capped to the readable column width and left-aligned
    /// to line up with content above. The transport renders without its
    /// own rounded card (`showCard: false`) since the bar itself provides
    /// the surface.
    var pinnedTransportBar: some View {
        VStack(spacing: 0) {
            Divider()

            AudioTransport(
                isPlaying: viewModel.isPlaying,
                currentTime: viewModel.playbackCurrentTime,
                duration: viewModel.playbackDuration,
                isDisabled: !viewModel.canPlay,
                rate: viewModel.playbackRate,
                speedOptions: MeetingDetailViewModel.speedOptions,
                showCard: false,
                onPlayPause: { viewModel.playPause() },
                onSeek: { viewModel.seek(to: $0) },
                onRate: { viewModel.setPlaybackRate($0) }
            )
            .padding(.horizontal, Tokens.homeHorizontalPadding)
            .padding(.vertical, Tokens.spacingSM)
            .frame(
                maxWidth: Tokens.readableContentMaxWidth,
                alignment: .leading
            )
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .pinnedBarBackground()
        .background(GeometryReader { transportProxy in
            Color.clear
                .preference(
                    key: TransportHeightKey.self,
                    value: transportProxy.size.height
                )
        })
    }

    /// Header + calendar card + tab bar, measured for the chrome-height
    /// preference key. AudioTransport is now pinned to the bottom of
    /// the panel (see `pinnedTransportBar`), outside this scroll region.
    var chrome: some View {
        VStack(alignment: .leading, spacing: Tokens.spacingMD) {
            header

            if viewModel.showReTranscribeAfterCorrection {
                reTranscribePrompt
            }

            if let card = viewModel.calendarCard {
                CalendarInfoCard(
                    data: card,
                    onOpenInCalendar: { viewModel.openInCalendar() }
                )
            }

            tabBar
        }
        .background(GeometryReader { chromeProxy in
            Color.clear
                .preference(
                    key: ChromeHeightKey.self,
                    value: chromeProxy.size.height
                )
        })
    }

    var overflowMenu: some View {
        Menu {
            if viewModel.hasAudioFiles {
                Button {
                    viewModel.revealInFinder()
                } label: {
                    Label(
                        "Reveal recording in Finder",
                        systemImage: "folder"
                    )
                }
            }

            if viewModel.canReTranscribe {
                Button {
                    Task { await viewModel.reTranscribe() }
                } label: {
                    Label(
                        "Re-transcribe",
                        systemImage: "arrow.triangle.2.circlepath"
                    )
                }
            }

            Divider()

            if viewModel.hasCalendarContext {
                Button {
                    Task {
                        await viewModel.presentAssociationCorrection()
                    }
                } label: {
                    Label(
                        "Change Calendar Event\u{2026}",
                        systemImage: "calendar"
                    )
                }

                Button {
                    Task { await viewModel.removeAssociation() }
                } label: {
                    Label(
                        "Unlink Calendar Event",
                        systemImage: "calendar.badge.minus"
                    )
                }
            } else {
                Button {
                    Task {
                        await viewModel.presentAssociationCorrection()
                    }
                } label: {
                    Label(
                        "Link Calendar Event\u{2026}",
                        systemImage: "calendar.badge.plus"
                    )
                }
            }

            Divider()

            Button(role: .destructive) {
                viewModel.requestDelete()
            } label: {
                Label("Delete Meeting\u{2026}", systemImage: "trash")
            }
            .disabled(viewModel.isDeleting)
        } label: {
            // .menuStyle(.button) + .buttonStyle(.plain) renders the
            // label as a plain view, honoring .font() -- unlike
            // .borderlessButton which clamps to a fixed control metric
            // (FB9754368).
            Image(systemName: "ellipsis.circle")
                .font(.system(size: 18, weight: .light))
                .foregroundStyle(.inkSecondary)
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
    }

    var metaLine: some View {
        HStack(spacing: Tokens.spacingSM) {
            Text(viewModel.formattedDate)
                .font(.monoMeta)
                .foregroundStyle(.inkSecondary)

            if let duration = viewModel.formattedDuration {
                Text("\u{00B7}")
                    .foregroundStyle(.inkTertiary)
                Text(duration)
                    .font(.monoMeta)
                    .foregroundStyle(.inkSecondary)
            }

            if let platform = viewModel.calendarContext?.conferencePlatform {
                Text("\u{00B7}")
                    .foregroundStyle(.inkTertiary)
                SourcePill(platform: platform)
            }
        }
    }

    var tabBar: some View {
        HStack {
            Picker("", selection: $viewModel.selectedTab) {
                ForEach(MeetingDetailViewModel.Tab.allCases, id: \.self) { option in
                    Text(option.rawValue).tag(option)
                }
            }
            .pickerStyle(.segmented)
            .fixedSize()

            Spacer()

            if viewModel.selectedTab == .transcript, viewModel.versions.count > 1 {
                versionPicker
            }

            Button {
                if viewModel.selectedTab == .transcript {
                    viewModel.copyTranscript()
                } else {
                    viewModel.copyNotes()
                }
                didCopy = true
                copyResetTask?.cancel()
                copyResetTask = Task {
                    try? await Task.sleep(for: .seconds(1.5))
                    guard !Task.isCancelled else { return }
                    didCopy = false
                }
            } label: {
                Label(
                    didCopy ? "Copied" : "Copy",
                    systemImage: didCopy ? "checkmark" : "doc.on.doc"
                )
                .transaction { $0.animation = nil }
            }
            .buttonStyle(.borderless)
            .controlSize(.small)
            .foregroundStyle(didCopy ? .sage : .inkSecondary)
            .disabled(!canCopy)
        }
    }

    var versionPicker: some View {
        VersionPicker(
            versions: viewModel.versions.map { version in
                VersionPickerItem(
                    id: version.id,
                    dateText: Self.versionDateFormatter.string(
                        from: version.createdAt
                    ),
                    methodLabel: version.methodId,
                    isPreferred: version.isPreferred
                )
            },
            // Safe: the picker is only shown when versions.count > 1,
            // which guarantees activeVersionID is non-nil (a preferred
            // or selected version always exists when versions are loaded).
            selectedID: viewModel.activeVersionID ?? UUID(),
            onSelect: { id in
                Task { await viewModel.selectVersion(id) }
            }
        )
    }

    var reTranscribePrompt: some View {
        HStack {
            Text(
                "Calendar event changed. Re-transcribe for updated vocabulary?"
            )
            .font(.caption)
            .foregroundStyle(.inkSecondary)

            Spacer()

            if viewModel.canReTranscribe {
                Button("Re-transcribe") {
                    Task {
                        await viewModel.reTranscribeAfterCorrection()
                    }
                }
                .buttonStyle(.bordered)
                .controlSize(.mini)
            }

            Button("Dismiss") {
                viewModel.dismissReTranscribePrompt()
            }
            .buttonStyle(.borderless)
            .controlSize(.mini)
        }
        .padding(Tokens.spacingSM)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(Color.accentWashSoft)
        )
    }
}

// MARK: - Tab content

private extension MeetingDetailView {
    @ViewBuilder
    func tabContent(fill: CGFloat) -> some View {
        switch viewModel.selectedTab {
        case .notes:
            notesTabContent(fill: fill)

        case .transcript:
            transcriptTabContent(fill: fill)
        }
    }

    /// Notes tab: MarkdownEditor sized to fill the remaining viewport.
    /// A transparent click-forwarder sits behind the editor so clicking
    /// empty space below the placeholder focuses the text view.
    func notesTabContent(fill: CGFloat) -> some View {
        MarkdownEditor(
            text: Binding(
                get: { viewModel.notes },
                set: { viewModel.updateNotes($0) }
            ),
            documentId: viewModel.meetingID.uuidString,
            placeholder: "Add notes\u{2026}"
        )
        .frame(height: fill)
        .background(TextViewFocusForwarder())
        .overlay(
            RoundedRectangle(cornerRadius: Tokens.buttonRadius)
                .stroke(Color.cardStroke, lineWidth: 0.5)
        )
    }
}

// MARK: - Transcript tab states

private extension MeetingDetailView {
    @ViewBuilder
    func transcriptTabContent(fill: CGFloat) -> some View {
        switch viewModel.displayState {
        case let .processing(message, subtitle):
            centeredStatus(message: message, subtitle: subtitle)
                .frame(height: fill)

        case .transcript:
            transcriptReadyContent(fill: fill)

        case let .failed(message, retriable):
            failedContent(message: message, retriable: retriable)
                .frame(height: fill)
        }
    }

    func centeredStatus(message: String, subtitle: String?) -> some View {
        VStack {
            Spacer()
            StatusRow(message, subtitle: subtitle)
            Spacer()
        }
        .frame(maxWidth: .infinity)
    }

    @ViewBuilder
    func transcriptReadyContent(fill: CGFloat) -> some View {
        // A: read the pre-built cached attributed string (rebuilt reactively
        // by the VM when inputs change -- never mutated during render).
        if let attributed = viewModel.cachedTranscriptAttributed {
            SelectableTranscriptView(
                attributed: attributed,
                onSeek: { viewModel.seek(to: $0) }
            )
            .frame(minHeight: fill, alignment: .topLeading)
        } else if viewModel.hasBeenTranscribed {
            // C: transcription ran but produced no text.
            emptyTranscriptionContent
                .frame(height: fill)
        } else {
            // C: never transcribed -- offer "Transcribe now".
            notTranscribedContent
                .frame(height: fill)
        }
    }

    /// Transcription ran but produced no segments.
    var emptyTranscriptionContent: some View {
        VStack(spacing: Tokens.spacingSM) {
            Spacer()
            Text("Transcription empty")
                .font(.system(size: 15))
                .foregroundStyle(.inkSecondary)
            Spacer()
        }
        .frame(maxWidth: .infinity)
    }

    /// No transcription has been attempted yet.
    var notTranscribedContent: some View {
        VStack(spacing: Tokens.spacingSM) {
            Spacer()
            Text("No transcript yet")
                .font(.system(size: 15))
                .foregroundStyle(.inkSecondary)
            if viewModel.canReTranscribe {
                Button("Transcribe now") {
                    Task { await viewModel.reTranscribe() }
                }
                .buttonStyle(.borderless)
                .controlSize(.small)
            }
            Spacer()
        }
        .frame(maxWidth: .infinity)
    }

    func failedContent(message: String, retriable: Bool) -> some View {
        VStack {
            Spacer()
            Banner(
                message,
                style: .error,
                actionLabel: retriable ? "Retry" : nil,
                action: retriable
                    ? { Task { await viewModel.retry() } }
                    : nil
            )
            .frame(maxWidth: 500)
            Spacer()
        }
        .frame(maxWidth: .infinity)
    }
}

// MARK: - Layout preference keys

private struct ChromeHeightKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}

private struct TransportHeightKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}

// MARK: - Pinned bar background (glass / vibrancy)

/// Applies Liquid Glass on macOS 26+ and falls back to the vibrancy
/// material on older macOS versions.
private struct PinnedBarBackgroundModifier: ViewModifier {
    func body(content: Content) -> some View {
        if #available(macOS 26.0, *) {
            content.glassEffect(.regular, in: Rectangle())
        } else {
            content.background(.ultraThinMaterial)
        }
    }
}

private extension View {
    func pinnedBarBackground() -> some View {
        modifier(PinnedBarBackgroundModifier())
    }
}

// MARK: - Click-to-focus helper for the MarkdownEditor

/// An `NSViewRepresentable` that catches mouse clicks in the empty area
/// of the MarkdownEditor's scroll view and makes the `NSTextView` the
/// first responder. Placed as a `.background` of the editor so it sits
/// behind the scroll view and only receives clicks that the text view
/// itself doesn't consume (i.e. clicks below the text content).
private struct TextViewFocusForwarder: NSViewRepresentable {
    func makeNSView(context _: Context) -> FocusForwarderView {
        FocusForwarderView()
    }

    func updateNSView(_: FocusForwarderView, context _: Context) {}
}

/// Transparent view that, on click, walks its sibling/parent hierarchy
/// to find the nearest `NSTextView` and makes it first responder.
private final class FocusForwarderView: NSView {
    override func mouseDown(with event: NSEvent) {
        super.mouseDown(with: event)
        // Walk the superview chain to find the NSScrollView that hosts
        // the MarkdownEditor's text view.
        if let textView = findTextView() {
            window?.makeFirstResponder(textView)
        }
    }

    /// Walks the superview chain looking for an NSScrollView whose
    /// document view contains an NSTextView.
    private func findTextView() -> NSTextView? {
        var current: NSView? = superview
        while let view = current {
            if let scrollView = view as? NSScrollView,
               let textView = findTextView(in: scrollView.documentView)
            {
                return textView
            }
            // Also check siblings
            for sibling in view.subviews {
                if let scrollView = sibling as? NSScrollView,
                   let textView = findTextView(in: scrollView.documentView)
                {
                    return textView
                }
            }
            current = view.superview
        }
        return nil
    }

    /// Recursively searches for an NSTextView within a view hierarchy.
    private func findTextView(in view: NSView?) -> NSTextView? {
        guard let view else { return nil }
        if let textView = view as? NSTextView { return textView }
        for subview in view.subviews {
            if let found = findTextView(in: subview) { return found }
        }
        return nil
    }
}

// MARK: - Event Picker Sheet (uses shared DesignSystem.EventPickerSheet)

#Preview("Meeting Detail - Processing") {
    let core = try! PreviewAppCore.make() // swiftlint:disable:this force_try
    let viewModel = MeetingDetailViewModel(core: core, meetingID: UUID())
    MeetingDetailView(viewModel: viewModel)
        .frame(width: 800, height: 600)
}
