import AppCore
import DataStore
import DesignSystem
import SwiftUI

/// The sidebar's scrollable list of past meetings, grouped by effective date.
///
/// Groups: Today / Yesterday / This Week / Earlier. Each row shows the
/// meeting title and a relative date. Selecting a row routes the detail
/// pane to that meeting via `MeetingListViewModel`.
public struct MeetingListView: View {
    @Bindable private var viewModel: MeetingListViewModel

    public init(viewModel: MeetingListViewModel) {
        self.viewModel = viewModel
    }

    public var body: some View {
        Group {
            if viewModel.groupedMeetings.isEmpty {
                Text("No recordings yet")
                    .font(Tokens.metadataFont)
                    .foregroundStyle(Tokens.secondaryText)
                    .padding(.vertical, Tokens.spacingSM)
            } else {
                ForEach(viewModel.groupedMeetings) { group in
                    Section {
                        ForEach(group.meetings) { meeting in
                            Button {
                                viewModel.select(meeting.id)
                            } label: {
                                meetingRow(meeting)
                            }
                            .buttonStyle(.plain)
                            .padding(.vertical, Tokens.spacingXS)
                            .padding(.horizontal, Tokens.spacingSM)
                            .background(
                                viewModel.selectedMeetingID == meeting.id
                                    ? Color.accentColor.opacity(0.15)
                                    : Color.clear,
                                in: RoundedRectangle(cornerRadius: 4)
                            )
                        }
                    } header: {
                        Text(group.title)
                            .font(Tokens.sectionHeaderFont)
                            .foregroundStyle(Tokens.secondaryText)
                            .padding(.horizontal, Tokens.spacingSM)
                            .padding(.top, Tokens.spacingSM)
                    }
                }
            }
        }
    }

    private func meetingRow(_ meeting: MeetingSummary) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(meeting.title)
                .font(.body)
                .lineLimit(1)

            Text(MeetingListViewModel.secondLineText(for: meeting))
                .font(Tokens.metadataFont)
                .foregroundStyle(Tokens.secondaryText)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
    }
}

#Preview("Meeting List - Empty") {
    MeetingListView(viewModel: .preview())
        .frame(width: 200)
}

#Preview("Meeting List - With Meetings") {
    MeetingListView(viewModel: .preview())
        .frame(width: 200)
}
