import AppCore
import AppKit
import DataStore
import DesignSystem
import SwiftUI

/// The Meetings screen's left-bar list: a native `List` with pinned
/// section headers (browse mode) or flat ranked results (search mode).
///
/// Uses `List(selection: Binding<Set<UUID>>)` for the platform's native
/// accent highlight, keyboard navigation (arrow up/down), and built-in
/// shift/cmd multi-select.
public struct MeetingListView: View {
    @Bindable private var viewModel: MeetingListViewModel

    public init(viewModel: MeetingListViewModel) {
        self.viewModel = viewModel
    }

    public var body: some View {
        // Empty states render OUTSIDE the List so ContentUnavailableView
        // centers vertically in the full pane instead of pinning to a row.
        if viewModel.mode == .browse, viewModel.groups.isEmpty {
            ContentUnavailableView {
                Label {
                    Text("No Recordings")
                        .font(.serifHeadline)
                } icon: {
                    Image(systemName: "waveform")
                }
            } description: {
                Text("Recorded meetings will appear here.")
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if viewModel.mode == .search,
                  !viewModel.isSearching, // still in-flight -> fall through to List/spinner
                  viewModel.results.isEmpty
        {
            ContentUnavailableView.search(text: viewModel.query)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            List(
                selection: Binding(
                    get: { viewModel.selectedIDs },
                    set: { viewModel.select($0) }
                )
            ) {
                // The suppressor must live INSIDE the List's content so its
                // backing NSView is a descendant of the NSTableView.  Placing
                // it on the first Section / row and walking *up* the superview
                // chain guarantees we target THIS list's table, not a sibling.
                switch viewModel.mode {
                case .browse:
                    browseContent
                        .background(SelectionHighlightSuppressor())

                case .search:
                    searchContent
                        .background(SelectionHighlightSuppressor())
                }
            }
            .listStyle(.inset)
            .scrollContentBackground(.hidden)
            .background(Color.listPaneBackground)
            .onDeleteCommand {
                viewModel.requestDeleteSelection()
            }
            .confirmationDialog(
                deleteDialogTitle,
                isPresented: $viewModel.showDeleteConfirmation,
                titleVisibility: .visible
            ) {
                Button("Delete", role: .destructive) {
                    Task { await viewModel.confirmDelete() }
                }
                Button("Cancel", role: .cancel) {
                    viewModel.cancelDelete()
                }
            } message: {
                Text(deleteDialogMessage)
            }
        }
    }

    // MARK: - Delete confirmation copy

    private var deleteDialogTitle: String {
        let count = viewModel.deleteConfirmationCount
        if count == 1 {
            return "Delete this meeting?"
        }
        return "Delete \(count) meetings?"
    }

    private var deleteDialogMessage: String {
        let count = viewModel.deleteConfirmationCount
        if count == 1 {
            return "This meeting and its recording will be permanently deleted."
        }
        return "These \(count) meetings and their recordings will be permanently deleted."
    }

    // MARK: - Browse mode (grouped by date)

    private var browseContent: some View {
        ForEach(viewModel.groups) { group in
            Section {
                ForEach(group.meetings) { meeting in
                    meetingRow(meeting)
                        .tag(meeting.id)
                }
            } header: {
                Text(group.title)
                    .kicker()
                    .foregroundStyle(.inkTertiary)
            }
        }
    }

    // MARK: - Search mode (flat results)

    @ViewBuilder
    private var searchContent: some View {
        if viewModel.isSearching {
            HStack {
                Spacer()
                ProgressView()
                Spacer()
            }
            .padding(.vertical, Tokens.spacingLG)
        } else {
            ForEach(viewModel.results) { hit in
                searchRow(hit)
                    .tag(hit.id)
            }
        }
    }

    // MARK: - Row views

    private func meetingRow(_ meeting: MeetingSummary) -> some View {
        let isSelected = viewModel.selectedIDs.contains(meeting.id)
        return VStack(alignment: .leading, spacing: 2) {
            Text(meeting.title)
                .font(.system(size: 13.5, weight: .medium))
                .foregroundStyle(isSelected ? .onAccent : .ink)
                .lineLimit(1)

            Text(MeetingListViewModel.secondLineText(for: meeting))
                .font(.monoMeta)
                .foregroundStyle(isSelected ? .onAccentMuted : .inkSecondary)

            if !meeting.tags.isEmpty {
                tagLine(meeting.tags, isSelected: isSelected)
                    .padding(.top, 4)
            }
        }
        .listRowSeparator(.hidden)
        .listRowBackground(selectionBackground(isSelected))
    }

    /// The custom selection background: solid sage fill when selected,
    /// clear when not. Paints our own selection independent of the system accent.
    @ViewBuilder
    private func selectionBackground(_ isSelected: Bool) -> some View {
        if isSelected {
            RoundedRectangle(cornerRadius: 8)
                .fill(Color.accentFill)
                .padding(.horizontal, 8)
        } else {
            Color.clear
        }
    }

    private func tagLine(_ tags: [TagData], isSelected: Bool) -> some View {
        let sorted = tags.sorted {
            $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
        }
        let visible = Array(sorted.prefix(3))
        let overflow = sorted.count - visible.count

        return HStack(spacing: 5) {
            ForEach(visible) { tag in
                TagPill(tag: tag, size: .compact, onAccent: isSelected)
            }
            if overflow > 0 {
                Text("+\(overflow)")
                    .font(.monoBadge)
                    .foregroundStyle(
                        isSelected ? .onAccentMuted : .inkTertiary
                    )
            }
        }
    }

    private func searchRow(_ hit: SearchHit) -> some View {
        let isSelected = viewModel.selectedIDs.contains(hit.id)
        return VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text(hit.title)
                    .font(.system(size: 13.5, weight: .medium))
                    .foregroundStyle(isSelected ? .onAccent : .ink)
                    .lineLimit(1)
                Spacer()
                Text(TimeFormatting.shortDate(hit.date))
                    .font(.monoMeta)
                    .foregroundStyle(isSelected ? .onAccentMuted : .inkSecondary)
            }
            Text(
                "matches: \(MeetingListViewModel.matchedFieldsText(hit.matchedFields))"
            )
            .font(.caption)
            .foregroundStyle(isSelected ? .onAccentMuted : .inkTertiary)
        }
        .listRowSeparator(.hidden)
        .listRowBackground(selectionBackground(isSelected))
    }
}

// MARK: - Selection highlight suppressor (AppKit bridge)

/// An invisible `NSViewRepresentable` placed as a `.background()` on
/// content **inside** the `List { … }` closure so its backing `NSView` is
/// a descendant of the `NSTableView`.  It walks *up* the superview chain
/// to find the enclosing `NSTableView` and sets
/// `selectionHighlightStyle = .none`, suppressing the system-accent
/// selection highlight entirely.  The selection *model* (keyboard nav,
/// arrow keys, multi-select) is unaffected — only the visual drawing
/// is suppressed, letting `MeetingListView` paint its own solid sage
/// fill via `.listRowBackground`.
///
/// The suppression fires on three complementary triggers so it survives
/// hierarchy rebuilds:
///   1. `viewDidMoveToSuperview()` — first insertion into the table
///   2. `viewDidMoveToWindow()` — window re-parenting / tab changes
///   3. `updateNSView` — every SwiftUI re-render
///
/// Modeled on `SearchFieldFocuser` in `AppShellUI/AppShellView.swift`
/// and the placement pattern from SwiftUI-Introspect (`scope: .ancestor`).
private struct SelectionHighlightSuppressor: NSViewRepresentable {
    func makeNSView(context _: Context) -> SuppressorView {
        SuppressorView()
    }

    func updateNSView(_ nsView: SuppressorView, context _: Context) {
        // Re-apply on every SwiftUI update in case the hierarchy is rebuilt.
        nsView.suppressSelectionHighlight()
    }

    final class SuppressorView: NSView {
        override func viewDidMoveToSuperview() {
            super.viewDidMoveToSuperview()
            suppressSelectionHighlight()
        }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            suppressSelectionHighlight()
        }

        /// Walks up the superview chain to find the nearest `NSTableView`
        /// and sets `selectionHighlightStyle = .none`.
        func suppressSelectionHighlight() {
            // Defer to the next run-loop tick so SwiftUI's hosting-view
            // hierarchy is fully assembled before we walk it.
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                var ancestor: NSView? = superview
                // Walk up at most 30 levels — the NSTableView is typically
                // within ~5-10 levels when placed inside the List content.
                for _ in 0 ..< 30 {
                    guard let current = ancestor else { break }
                    if let tableView = current as? NSTableView {
                        tableView.selectionHighlightStyle = .none
                        return
                    }
                    ancestor = current.superview
                }
            }
        }
    }
}

#if DEBUG
    #Preview("Meeting List - Browse Empty") {
        MeetingListView(viewModel: .previewEmpty())
            .frame(width: 280, height: 400)
    }

    #Preview("Meeting List - Browse Populated") {
        MeetingListView(viewModel: .previewBrowse())
            .frame(width: 280, height: 400)
    }

    #Preview("Meeting List - Search") {
        MeetingListView(viewModel: .previewSearch())
            .frame(width: 280, height: 400)
    }
#endif
