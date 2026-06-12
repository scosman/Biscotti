import AppCore
import Calendar
import DesignSystem
import HomeUI
import MeetingDetailUI
import MeetingListUI
import OnboardingUI
import RecordingUI
import SettingsUI
import SwiftUI

/// The main app window: a `NavigationSplitView` with a sidebar (Home +
/// Record indicator + Past Meetings + Upcoming + Settings) and a detail
/// pane routed by `AppCore.route`.
public struct AppShellView: View {
    @Bindable private var viewModel: AppShellViewModel

    /// Bound to the `.searchable` field. Two-way synced with AppCore's
    /// `meetingsQuery` via `.onChange` to avoid feedback loops.
    @State private var searchText = ""

    public init(viewModel: AppShellViewModel) {
        self.viewModel = viewModel
    }

    public var body: some View {
        Group {
            if viewModel.showOnboarding {
                // Full-window takeover for onboarding (C5)
                OnboardingView(
                    viewModel: viewModel.onboardingViewModel
                )
            } else {
                NavigationSplitView {
                    sidebar
                } detail: {
                    detailContent
                }
                .toolbar {
                    ToolbarItem(placement: .navigation) {
                        Button {
                            viewModel.showHome()
                        } label: {
                            Image(systemName: "house")
                        }
                        .help("Home")
                    }
                }
                .searchable(
                    text: $searchText,
                    placement: .toolbar,
                    prompt: "Search meetings\u{2026}"
                )
                .onChange(of: searchText) { _, newValue in
                    if newValue != viewModel.meetingsQuery {
                        viewModel.setMeetingsQuery(newValue)
                    }
                }
                .onChange(of: viewModel.meetingsQuery) { _, newValue in
                    if newValue != searchText {
                        searchText = newValue
                    }
                }
            }
        }
        .task { await viewModel.onLaunch() }
    }

    // MARK: - Sidebar

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 0) {
            recordSection
                .padding(.horizontal, Tokens.spacingSM)

            if viewModel.showRecordingIndicator {
                recordingIndicator
                    .padding(.horizontal, Tokens.spacingSM)
            }

            Divider()
                .padding(.vertical, Tokens.spacingSM)

            // Home row
            homeRow
                .padding(.horizontal, Tokens.spacingSM)

            // Past Meetings row
            pastMeetingsRow
                .padding(.horizontal, Tokens.spacingSM)

            Divider()
                .padding(.vertical, Tokens.spacingSM)

            // Upcoming section
            if viewModel.hasCalendarAccess,
               !viewModel.upcomingEvents.isEmpty
            {
                upcomingSection
            }

            Spacer()

            Divider()
                .padding(.vertical, Tokens.spacingSM)

            // Settings (pinned bottom)
            settingsRow
                .padding(.horizontal, Tokens.spacingSM)
                .padding(.bottom, Tokens.spacingSM)
        }
        .frame(minWidth: 180, idealWidth: 220)
    }

    private var recordSection: some View {
        RecordButton(isDisabled: viewModel.recordButtonDisabled) {
            Task { await viewModel.startRecording() }
        }
    }

    private var recordingIndicator: some View {
        Button {
            viewModel.showRecording()
        } label: {
            HStack(spacing: Tokens.spacingSM) {
                Circle()
                    .fill(Tokens.recordingRed)
                    .frame(width: 8, height: 8)

                Text("Recording\u{2026}")
                    .font(.callout)

                Spacer()

                Text(viewModel.recordingElapsedText)
                    .font(.callout.monospacedDigit())
                    .foregroundStyle(Tokens.secondaryText)
            }
            .padding(.vertical, Tokens.spacingXS)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private var homeRow: some View {
        Button {
            viewModel.showHome()
        } label: {
            HStack(spacing: Tokens.spacingSM) {
                Image(systemName: "house")
                    .foregroundStyle(
                        viewModel.route == .home
                            ? Color.accentColor
                            : Tokens.secondaryText
                    )
                Text("Home")
                    .font(.body)
                Spacer()
            }
            .padding(.vertical, Tokens.spacingXS)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .background(
            viewModel.route == .home
                ? Color.accentColor.opacity(0.15)
                : Color.clear,
            in: RoundedRectangle(cornerRadius: 4)
        )
    }

    private var pastMeetingsRow: some View {
        Button {
            viewModel.showMeetings()
        } label: {
            HStack(spacing: Tokens.spacingSM) {
                Image(systemName: "clock")
                    .foregroundStyle(
                        viewModel.route == .meetings
                            ? Color.accentColor
                            : Tokens.secondaryText
                    )
                Text("Past Meetings")
                    .font(.body)
                Spacer()
            }
            .padding(.vertical, Tokens.spacingXS)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .background(
            viewModel.route == .meetings
                ? Color.accentColor.opacity(0.15)
                : Color.clear,
            in: RoundedRectangle(cornerRadius: 4)
        )
    }

    private var upcomingSection: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("UPCOMING")
                .font(Tokens.sectionHeaderFont)
                .foregroundStyle(Tokens.secondaryText)
                .padding(.horizontal, Tokens.spacingMD)
                .padding(.bottom, Tokens.spacingXS)

            ForEach(viewModel.upcomingEvents) { event in
                Button {
                    viewModel.selectEvent(event.id)
                } label: {
                    UpcomingEventRow(
                        title: event.title,
                        timeText: viewModel.tickTimeText(for: event),
                        platformBadge: event.conferencePlatform,
                        twoLine: true
                    )
                    .padding(.vertical, Tokens.spacingXS)
                    .padding(.horizontal, Tokens.spacingSM)
                }
                .buttonStyle(.plain)
                .background(
                    viewModel.route == .event(event.id)
                        ? Color.accentColor.opacity(0.15)
                        : Color.clear,
                    in: RoundedRectangle(cornerRadius: 4)
                )
            }

            Divider()
                .padding(.vertical, Tokens.spacingSM)
        }
    }

    private var settingsRow: some View {
        Button {
            viewModel.showSettings()
        } label: {
            HStack(spacing: Tokens.spacingSM) {
                Image(systemName: "gearshape")
                    .foregroundStyle(
                        viewModel.route == .settings
                            ? Color.accentColor
                            : Tokens.secondaryText
                    )
                Text("Settings")
                    .font(.body)
                Spacer()
            }
            .padding(.vertical, Tokens.spacingXS)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .background(
            viewModel.route == .settings
                ? Color.accentColor.opacity(0.15)
                : Color.clear,
            in: RoundedRectangle(cornerRadius: 4)
        )
    }

    // MARK: - Detail pane

    @ViewBuilder
    private var detailContent: some View {
        switch viewModel.route {
        case .home:
            HomeView(viewModel: viewModel.homeViewModel)

        case .recording:
            RecordingView(
                viewModel: viewModel.recordingViewModel
            )

        case .meetings:
            meetingsSplit

        case let .event(key):
            EventPreviewView(
                viewModel: viewModel.eventPreviewViewModel(for: key)
            )
            .id(key)

        case .settings:
            SettingsView(viewModel: viewModel.settingsViewModel)

        case .onboarding:
            // Handled by the full-window takeover above; should not reach here.
            EmptyView()
        }
    }

    /// The Meetings two-pane: native list + detail or placeholder.
    private var meetingsSplit: some View {
        MeetingsSplitView(viewModel: viewModel)
    }
}

/// Extracted to keep `AppShellView` under the type-body-length limit.
/// The Meetings two-pane: native list + detail or placeholder.
private struct MeetingsSplitView: View {
    let viewModel: AppShellViewModel

    var body: some View {
        HSplitView {
            MeetingListView(
                viewModel: viewModel.meetingListViewModel
            )
            .frame(minWidth: 220, idealWidth: 280, maxWidth: 420)

            Group {
                if let id = viewModel.meetingsSelection {
                    MeetingDetailView(
                        viewModel: viewModel.meetingDetailViewModel(for: id)
                    )
                    .id(id)
                } else {
                    ContentUnavailableView(
                        "No Meeting Selected",
                        systemImage: "quote.bubble",
                        description: Text(
                            "Select a meeting to see its transcript and details."
                        )
                    )
                }
            }
            .frame(minWidth: 360, maxWidth: .infinity)
        }
    }
}

#Preview("App Shell") {
    let core = try! PreviewAppCore.make() // swiftlint:disable:this force_try
    let viewModel = AppShellViewModel(core: core)
    AppShellView(viewModel: viewModel)
        .frame(width: 700, height: 500)
}
