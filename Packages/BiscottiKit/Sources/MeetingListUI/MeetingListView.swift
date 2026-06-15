import AppCore
import DataStore
import DesignSystem
import SwiftUI

/// The Meetings screen's left-bar list: a native `List` with pinned
/// section headers (browse mode) or flat ranked results (search mode).
///
/// Uses `List(selection:)` for the platform's native accent highlight
/// and keyboard navigation (arrow up/down drives the detail pane).
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
                  !viewModel.isSearching, // still in-flight → fall through to List/spinner
                  viewModel.results.isEmpty
        {
            ContentUnavailableView.search(text: viewModel.query)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            List(
                selection: Binding(
                    get: { viewModel.selectedID },
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
        }
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
