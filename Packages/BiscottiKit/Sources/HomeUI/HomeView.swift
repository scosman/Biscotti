import AppCore
import Calendar
import DataStore
import DesignSystem
import SwiftUI

/// The Home screen: greeting, stat chips, upcoming meetings, and
/// recent meeting history in a centered column.
public struct HomeView: View {
    @Bindable private var viewModel: HomeViewModel

    public init(viewModel: HomeViewModel) {
        self.viewModel = viewModel
    }

    public var body: some View {
        GeometryReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    greetingBlock

                    if viewModel.showStatChips {
                        statChipsRow
                            .padding(.top, 14)
                    }

                    HomeUpcomingSection(viewModel: viewModel)
                        .padding(.top, Tokens.cardToGroupGap)

                    HomePastSection(viewModel: viewModel)
                        .padding(.top, Tokens.cardToGroupGap)

                    HomeFooter()
                }
                .frame(maxWidth: Tokens.homeColumnMaxWidth, alignment: .leading)
                .padding(.vertical, Tokens.homeVerticalPadding)
                .padding(.horizontal, Tokens.homeHorizontalPadding)
                .frame(maxWidth: .infinity)
                .frame(minHeight: proxy.size.height)
            }
        }
        .background(Tokens.contentBackground.ignoresSafeArea())
    }

    // MARK: - Greeting

    private var greetingBlock: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(viewModel.greeting)
                .font(Tokens.greetingFont)
                .tracking(Tokens.greetingTracking)
                .foregroundStyle(.primary)

            Text(viewModel.dateText)
                .font(Tokens.dateLine)
                .foregroundStyle(.secondary)
        }
    }

    // MARK: - Stat chips

    private var statChipsRow: some View {
        HStack(spacing: Tokens.statChipSpacing) {
            if let text = viewModel.meetingsLeftText {
                StatChip(
                    icon: "calendar",
                    tint: .accentColor,
                    text: text
                )
            }
            if let text = viewModel.nextInText {
                StatChip(
                    icon: "circle.fill",
                    tint: Tokens.liveGreen,
                    text: "Next \(text)"
                )
            }
        }
    }
}

// MARK: - Upcoming section (extracted to stay under type-body-length limit)

private struct HomeUpcomingSection: View {
    let viewModel: HomeViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HomeSharedViews.groupLabel("UPCOMING")
                .padding(.bottom, Tokens.groupToCardGap)

            if viewModel.showConnectCalendar {
                connectCalendarCard
            } else if viewModel.showNoUpcoming {
                noUpcomingCard
            } else if !viewModel.upcomingPreview.isEmpty {
                upcomingCard
            }
        }
    }

    private var connectCalendarCard: some View {
        VStack(spacing: Tokens.spacingSM) {
            Text("Connect your calendar to see upcoming meetings")
                .font(Tokens.metaText)
                .foregroundStyle(.secondary)

            Button("Allow Calendar Access") {
                Task { await viewModel.requestCalendarAccess() }
            }
            .buttonStyle(.bordered)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, Tokens.spacingLG)
        .homeCard()
    }

    private var noUpcomingCard: some View {
        Text("No meetings coming up")
            .font(Tokens.metaText)
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity)
            .padding(.vertical, Tokens.spacingLG)
            .homeCard()
    }

    private var upcomingCard: some View {
        VStack(spacing: 0) {
            ForEach(
                Array(viewModel.upcomingPreview.enumerated()),
                id: \.element.id
            ) { index, event in
                if index > 0 {
                    InsetDivider()
                }
                if index == 0, viewModel.heroEvent != nil {
                    heroRow(event: event)
                } else {
                    ordinaryUpcomingRow(event: event)
                }
            }
        }
        .homeCard()
    }

    // MARK: - Hero row

    private func heroRow(event: CalendarEvent) -> some View {
        let data = viewModel.avatarData(for: event)

        return Button {
            viewModel.selectEvent(event.id)
        } label: {
            HStack(alignment: .center, spacing: 0) {
                AvatarCluster(
                    people: data.people,
                    totalCount: data.total,
                    size: Tokens.heroAvatarSize
                )

                heroCenterStack(event: event, data: data)

                Spacer(minLength: 8)

                heroActions(event: event)
            }
            .padding(Tokens.heroPadding)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .background(Tokens.accentWashSoft)
    }

    private func heroCenterStack(
        event: CalendarEvent,
        data: (people: [AvatarPerson], total: Int)
    ) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 9) {
                Text(event.title)
                    .font(Tokens.heroTitle)
                    .lineLimit(1)

                if !data.people.isEmpty {
                    Text(
                        data.people.prefix(3)
                            .map(\.displayName)
                            .joined(separator: ", ")
                    )
                    .font(Tokens.metaText)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                }
            }

            HStack(spacing: 9) {
                Text(viewModel.tickTimeText(for: event))
                    .font(Tokens.metaTextMedium)
                    .foregroundStyle(Color.accentColor)

                Text(HomeSharedViews.formattedTime(event.start))
                    .font(Tokens.metaText)
                    .foregroundStyle(.secondary)

                if let platform = event.conferencePlatform {
                    MeetingPlatformChip(platform: platform)
                }
            }

            if let notes = event.notes, !notes.isEmpty {
                Text(notes)
                    .font(Tokens.metaText)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .padding(.top, 2)
            }
        }
    }

    private func heroActions(event: CalendarEvent) -> some View {
        VStack(spacing: 9) {
            Button {
                Task { await viewModel.joinAndRecord(event) }
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "record.circle")
                    Text(
                        viewModel.heroIsRecordOnly
                            ? "Record"
                            : "Join & Record"
                    )
                }
            }
            .buttonStyle(JoinRecordButtonStyle())
            .disabled(viewModel.recordDisabled)

            Button {
                viewModel.openInCalendar(event)
            } label: {
                Text("View in calendar")
                    .font(Tokens.metaText)
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
        }
        .padding(.leading, 16)
    }

    // MARK: - Ordinary upcoming row

    private func ordinaryUpcomingRow(
        event: CalendarEvent
    ) -> some View {
        let data = viewModel.avatarData(for: event)

        return Button {
            viewModel.selectEvent(event.id)
        } label: {
            HStack(alignment: .center, spacing: 0) {
                AvatarCluster(
                    people: data.people,
                    totalCount: data.total,
                    size: Tokens.avatarSize
                )

                VStack(alignment: .leading, spacing: 4) {
                    Text(event.title)
                        .font(Tokens.rowTitle)
                        .lineLimit(1)

                    HStack(spacing: 9) {
                        Text(viewModel.tickTimeText(for: event))
                            .font(Tokens.metaTextMedium)
                            .foregroundStyle(Color.accentColor)

                        Text(HomeSharedViews.formattedTime(event.start))
                            .font(Tokens.metaText)
                            .foregroundStyle(.secondary)

                        if let platform = event.conferencePlatform {
                            MeetingPlatformChip(platform: platform)
                        }
                    }
                }

                Spacer(minLength: 8)

                Image(systemName: "chevron.right")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.tertiary)
            }
            .padding(.vertical, Tokens.rowVerticalPadding)
            .padding(.horizontal, Tokens.rowHorizontalPadding)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Past Meetings section (extracted to stay under type-body-length limit)

private struct HomePastSection: View {
    let viewModel: HomeViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .firstTextBaseline) {
                HomeSharedViews.groupLabel("PAST MEETINGS")

                Spacer()

                Button {
                    viewModel.showMeetings()
                } label: {
                    HStack(spacing: 3) {
                        Text("See all")
                            .font(Tokens.metaText)
                        Image(systemName: "chevron.right")
                            .font(.system(size: 10, weight: .medium))
                    }
                    .foregroundStyle(Color.accentColor)
                }
                .buttonStyle(.plain)
            }
            .padding(.bottom, Tokens.groupToCardGap)

            if viewModel.showNoRecent {
                noRecordingsCard
            } else {
                pastCard
            }
        }
    }

    private var noRecordingsCard: some View {
        Text("No recordings yet")
            .font(Tokens.metaText)
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity)
            .padding(.vertical, Tokens.spacingLG)
            .homeCard()
    }

    private var pastCard: some View {
        VStack(spacing: 0) {
            ForEach(
                Array(viewModel.recentMeetings.enumerated()),
                id: \.element.id
            ) { index, meeting in
                if index > 0 {
                    InsetDivider()
                }
                pastRow(meeting: meeting)
            }
        }
        .homeCard()
    }

    private func pastRow(
        meeting: MeetingSummary
    ) -> some View {
        let data = viewModel.avatarData(for: meeting)

        return Button {
            viewModel.selectMeeting(meeting.id)
        } label: {
            HStack(alignment: .center, spacing: 0) {
                AvatarCluster(
                    people: data.people,
                    totalCount: data.total,
                    size: Tokens.avatarSize,
                    showLeadingRecordingAvatar: true
                )

                VStack(alignment: .leading, spacing: 4) {
                    Text(meeting.title)
                        .font(Tokens.rowTitle)
                        .lineLimit(1)

                    Text(viewModel.pastSecondLine(for: meeting))
                        .font(Tokens.metaText)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }

                Spacer(minLength: 8)

                Image(systemName: "chevron.right")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.tertiary)
            }
            .padding(.vertical, Tokens.rowVerticalPadding)
            .padding(.horizontal, Tokens.rowHorizontalPadding)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Footer (brand lockup)

/// A quiet brand sign-off at the bottom of the Home content column.
private struct HomeFooter: View {
    var body: some View {
        VStack(spacing: 3) {
            Text("Biscotti")
                .font(.system(size: 13, weight: .semibold))
                .tracking(-0.1)
                .foregroundStyle(.primary)
            Text("Total recall, total privacy.")
                .font(.system(size: 12))
                .foregroundStyle(.tertiary)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 30)
    }
}

// MARK: - Shared helpers

/// Shared view helpers used by the extracted section structs.
private enum HomeSharedViews {
    static func groupLabel(_ title: String) -> some View {
        Text(title)
            .font(Tokens.groupLabel)
            .tracking(Tokens.groupLabelTracking)
            .foregroundStyle(.secondary)
            .textCase(.uppercase)
            .padding(.leading, 4)
    }

    /// Formats an event start time as e.g. "9:00 AM".
    static func formattedTime(_ date: Date) -> String {
        timeFormatter.string(from: date)
    }

    private static let timeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "h:mm a"
        return formatter
    }()
}

#Preview("Home - Populated") {
    let core = try! PreviewAppCore.make() // swiftlint:disable:this force_try
    let viewModel = HomeViewModel(core: core)
    HomeView(viewModel: viewModel)
        .frame(width: 700, height: 600)
}

#Preview("Home - Empty") {
    let core = try! PreviewAppCore.make() // swiftlint:disable:this force_try
    let viewModel = HomeViewModel(core: core)
    HomeView(viewModel: viewModel)
        .frame(width: 700, height: 500)
}
