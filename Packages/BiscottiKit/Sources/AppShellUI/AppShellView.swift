import AppCore
import Calendar
import DesignSystem
import HomeUI
import MeetingDetailUI
import MeetingListUI
import OnboardingUI
import RecordingUI
import SearchUI
import SettingsUI
import SwiftUI

/// The main app window: a `NavigationSplitView` with a sidebar (Home +
/// Record indicator + Upcoming + Past grouped + Settings) and a detail
/// pane routed by `AppCore.route`.
public struct AppShellView: View {
    @Bindable private var viewModel: AppShellViewModel

    /// Bound to the `.searchable` field via `.searchFocused`. Setting this
    /// to `false` programmatically dismisses the search field's focus/caret.
    @FocusState private var isSearchFieldFocused: Bool

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
                .searchable(
                    text: $viewModel.searchText,
                    placement: .toolbar,
                    prompt: "Search meetings\u{2026}"
                )
                .searchFocused($isSearchFieldFocused)
                .onSubmit(of: .search) {
                    viewModel.onSearchSubmit()
                }
                .onChange(of: viewModel.searchText) { _, newValue in
                    viewModel.onSearchTextChange(newValue)
                }
                .onChange(of: isSearchFieldFocused) { _, focused in
                    if focused {
                        viewModel.onSearchFieldFocused()
                    }
                }
                .onChange(
                    of: viewModel.searchViewModel.dismissFocusCount
                ) {
                    isSearchFieldFocused = false
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

            Divider()
                .padding(.vertical, Tokens.spacingSM)

            // Upcoming section
            if viewModel.hasCalendarAccess,
               !viewModel.upcomingEvents.isEmpty
            {
                upcomingSection
            }

            // Past section
            Text("PAST")
                .font(Tokens.sectionHeaderFont)
                .foregroundStyle(Tokens.secondaryText)
                .padding(.horizontal, Tokens.spacingMD)
                .padding(.bottom, Tokens.spacingXS)

            ScrollView {
                MeetingListView(
                    viewModel: viewModel.meetingListViewModel
                )
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
                        platformBadge: event.conferencePlatform
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

        case let .meeting(meetingID):
            MeetingDetailView(
                viewModel: viewModel.meetingDetailViewModel(for: meetingID)
            )
            .id(meetingID)

        case let .event(key):
            EventPreviewView(
                viewModel: viewModel.eventPreviewViewModel(for: key)
            )
            .id(key)

        case .search:
            SearchView(viewModel: viewModel.searchViewModel)

        case .settings:
            SettingsView(viewModel: viewModel.settingsViewModel)

        case .onboarding:
            // Handled by the full-window takeover above; should not reach here.
            EmptyView()
        }
    }

    private var emptyPlaceholder: some View {
        VStack(spacing: Tokens.spacingSM) {
            Image(systemName: "waveform")
                .font(.largeTitle)
                .foregroundStyle(Tokens.secondaryText)
            Text("Select a meeting, or tap Record")
                .font(Tokens.metadataFont)
                .foregroundStyle(Tokens.secondaryText)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

#Preview("App Shell") {
    let core = try! PreviewAppCore.make() // swiftlint:disable:this force_try
    let viewModel = AppShellViewModel(core: core)
    AppShellView(viewModel: viewModel)
        .frame(width: 700, height: 500)
}
