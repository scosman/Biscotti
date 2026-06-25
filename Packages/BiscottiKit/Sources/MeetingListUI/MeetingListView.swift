import AppCore
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
                switch viewModel.mode {
                case .browse:
                    browseContent

                case .search:
                    searchContent
                }
            }
            .listStyle(.inset)
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
            Section(group.title) {
                ForEach(group.meetings) { meeting in
                    meetingRow(meeting)
                        .tag(meeting.id)
                }
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
        VStack(alignment: .leading, spacing: 2) {
            Text(meeting.title)
                .font(.body)
                .lineLimit(1)

            Text(MeetingListViewModel.secondLineText(for: meeting))
                .font(Tokens.metadataFont)
                .foregroundStyle(Tokens.secondaryText)

            if !meeting.tags.isEmpty {
                tagLine(meeting.tags)
                    .padding(.top, 4)
            }
        }
    }

    private func tagLine(_ tags: [TagData]) -> some View {
        let sorted = tags.sorted {
            $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
        }
        let visible = Array(sorted.prefix(3))
        let overflow = sorted.count - visible.count

        return HStack(spacing: 5) {
            ForEach(visible) { tag in
                TagPill(tag: tag, size: .compact)
            }
            if overflow > 0 {
                Text("+\(overflow)")
                    .font(.monoBadge)
                    .foregroundStyle(.inkSecondary)
            }
        }
    }

    private func searchRow(_ hit: SearchHit) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text(hit.title)
                    .font(.body)
                    .lineLimit(1)
                Spacer()
                Text(TimeFormatting.shortDate(hit.date))
                    .font(.monoMeta)
                    .foregroundStyle(Tokens.secondaryText)
            }
            Text(
                "matches: \(MeetingListViewModel.matchedFieldsText(hit.matchedFields))"
            )
            .font(.caption)
            .foregroundStyle(Tokens.secondaryText)
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
