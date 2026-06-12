import AppCore
import Calendar
import DataStore
import DesignSystem
import SwiftUI

/// The Home screen: app title, upcoming meeting previews, and recent
/// meeting history.
public struct HomeView: View {
    @Bindable private var viewModel: HomeViewModel

    public init(viewModel: HomeViewModel) {
        self.viewModel = viewModel
    }

    public var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Tokens.spacingLG) {
                // Header
                headerBlock

                // Upcoming section
                upcomingSection

                // Recent Meetings section
                recentSection
            }
            .frame(maxWidth: 600, alignment: .leading)
            .padding(Tokens.spacingXL)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    // MARK: - Header

    private var headerBlock: some View {
        VStack(alignment: .leading, spacing: Tokens.spacingXS) {
            Text("Biscotti")
                .font(.largeTitle)
                .fontWeight(.bold)

            Text("Private, on-device meeting transcripts")
                .font(.title3)
                .foregroundStyle(Tokens.secondaryText)
        }
    }

    // MARK: - Upcoming section

    @ViewBuilder
    private var upcomingSection: some View {
        if viewModel.showConnectCalendar {
            sectionCard {
                sectionHeader("UPCOMING")

                VStack(spacing: Tokens.spacingSM) {
                    Text("Connect your calendar to see upcoming meetings")
                        .font(Tokens.metadataFont)
                        .foregroundStyle(Tokens.secondaryText)

                    Button("Allow Calendar Access") {
                        Task { await viewModel.requestCalendarAccess() }
                    }
                    .buttonStyle(.bordered)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, Tokens.spacingSM)
            }
        } else if viewModel.showNoUpcoming {
            sectionCard {
                sectionHeader("UPCOMING")

                Text("No meetings coming up")
                    .font(Tokens.metadataFont)
                    .foregroundStyle(Tokens.secondaryText)
                    .padding(.vertical, Tokens.spacingSM)
            }
        } else if !viewModel.upcomingPreview.isEmpty {
            sectionCard {
                sectionHeader("UPCOMING")

                ForEach(
                    Array(viewModel.upcomingPreview.enumerated()),
                    id: \.element.id
                ) { index, event in
                    if index > 0 {
                        Divider()
                    }
                    Button {
                        viewModel.selectEvent(event.id)
                    } label: {
                        UpcomingEventRow(
                            title: event.title,
                            timeText: viewModel.tickTimeText(for: event),
                            platformBadge: event.conferencePlatform,
                            twoLine: true
                        )
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    // MARK: - Recent Meetings section

    private var recentSection: some View {
        sectionCard {
            sectionHeader("RECENT MEETINGS")

            if viewModel.showNoRecent {
                Text("No recordings yet")
                    .font(Tokens.metadataFont)
                    .foregroundStyle(Tokens.secondaryText)
                    .padding(.vertical, Tokens.spacingSM)
            } else {
                ForEach(
                    Array(viewModel.recentMeetings.enumerated()),
                    id: \.element.id
                ) { index, meeting in
                    if index > 0 {
                        Divider()
                    }
                    Button {
                        viewModel.selectMeeting(meeting.id)
                    } label: {
                        recentMeetingRow(meeting)
                    }
                    .buttonStyle(.plain)
                }

                Divider()

                seeAllRow
            }
        }
    }

    private var seeAllRow: some View {
        Button {
            viewModel.showMeetings()
        } label: {
            HStack {
                Text("See all")
                    .font(.body)
                    .foregroundStyle(Tokens.secondaryText)
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.caption)
                    .foregroundStyle(Tokens.secondaryText)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func recentMeetingRow(
        _ meeting: MeetingSummary
    ) -> some View {
        VStack(alignment: .leading, spacing: Tokens.spacingXS) {
            Text(meeting.title)
                .font(.body)
                .lineLimit(1)

            Text(HomeViewModel.recentSecondLine(for: meeting))
                .font(Tokens.metadataFont)
                .foregroundStyle(Tokens.secondaryText)
        }
        .contentShape(Rectangle())
    }

    // MARK: - Shared card / header helpers

    private func sectionHeader(_ title: String) -> some View {
        Text(title)
            .font(Tokens.sectionHeaderFont)
            .foregroundStyle(Tokens.secondaryText)
    }

    private func sectionCard(
        @ViewBuilder content: () -> some View
    ) -> some View {
        VStack(alignment: .leading, spacing: Tokens.spacingSM) {
            content()
        }
        .padding(Tokens.spacingSM)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(Color.secondary.opacity(0.06))
        )
    }
}

#Preview("Home - Populated") {
    let core = try! PreviewAppCore.make() // swiftlint:disable:this force_try
    let viewModel = HomeViewModel(core: core)
    HomeView(viewModel: viewModel)
        .frame(width: 500, height: 500)
}

#Preview("Home - Empty") {
    let core = try! PreviewAppCore.make() // swiftlint:disable:this force_try
    let viewModel = HomeViewModel(core: core)
    HomeView(viewModel: viewModel)
        .frame(width: 500, height: 400)
}
