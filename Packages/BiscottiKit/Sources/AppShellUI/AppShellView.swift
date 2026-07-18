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
/// Past Meetings + Upcoming + Settings) and a detail pane routed by
/// `AppCore.route`. The stateful Record button lives in the toolbar.
public struct AppShellView: View {
    @Bindable private var viewModel: AppShellViewModel

    /// Bound to the search field in the toolbar. Two-way synced with
    /// AppCore's `meetingsQuery` via `.onChange` to avoid feedback loops.
    @State private var searchText = ""

    /// Drives focus of the native `.searchable` field via `.searchFocused`
    /// (available on macOS 15+). Set when `focusSearch()` bumps
    /// `searchFocusToken` (⌘F).
    @FocusState private var searchFieldFocused: Bool

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
                .background(Tokens.contentBackground)
            } else {
                mainWindow
            }
        }
        .background(Color.wall.ignoresSafeArea())
        // Two-way sync between the search field and AppCore's query.
        // Harmless during onboarding (no field is shown).
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
        .onChange(of: viewModel.showOnboarding) { _, isOnboarding in
            // Only reset when replaying (VM has advanced past welcome);
            // skip on first launch where the VM is already at defaults.
            if isOnboarding,
               viewModel.onboardingViewModel.currentStep != .welcome
            {
                viewModel.onboardingViewModel.resetForReplay()
            }
        }
        .task { await viewModel.onLaunch() }
    }

    // MARK: - Main window

    /// The single, all-native app window for every supported macOS version.
    ///
    /// Uses the system `.searchable` field in the toolbar. macOS anchors that
    /// field trailing-most and re-sorts it to the edge of its placement region,
    /// so the Record button sits to its *left* — we accept the platform's native
    /// ordering rather than fighting it with custom fields or toolbar hacks.
    /// Programmatic focus (⌘F / `focusSearch()`) drives the native field through
    /// `.searchFocused`, which is available on macOS 15+.
    private var mainWindow: some View {
        NavigationSplitView {
            sidebar
        } detail: {
            detailContent
        }
        .searchable(text: $searchText, prompt: "Search")
        .searchFocused($searchFieldFocused)
        .toolbar {
            homeToolbarItem
            ToolbarItem(placement: .primaryAction) {
                recordButton
            }
        }
        .onChange(of: viewModel.searchFocusToken) { _, _ in
            searchFieldFocused = true
        }
    }

    // MARK: - Sidebar

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Brand lockup
            sidebarBrandLockup
                .padding(.horizontal, Tokens.spacingSM)
                .padding(.bottom, Tokens.spacingSM)

            // Home row
            homeRow
                .padding(.horizontal, Tokens.spacingSM)

            // Past Meetings row
            pastMeetingsRow
                .padding(.horizontal, Tokens.spacingSM)

            Divider()
                .padding(.vertical, Tokens.spacingSM)

            // RECORDING NOW section (above Upcoming while recording)
            if viewModel.isRecording {
                RecordingNowSection(viewModel: viewModel)
            }

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
        .frame(minWidth: 100, idealWidth: 110)
        .background(Color.sidebarTint)
    }

    private var sidebarBrandLockup: some View {
        HStack(spacing: 6) {
            Image(systemName: "lock.shield.fill")
                .font(.system(size: 16))
                .foregroundStyle(.sage)
            Text("Biscotti")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(.ink)
        }
        .padding(.vertical, Tokens.spacingXS)
    }

    private var homeRow: some View {
        Button {
            viewModel.showHome()
        } label: {
            HStack(spacing: Tokens.spacingSM) {
                Image(systemName: "house")
                    .foregroundStyle(
                        viewModel.route == .home
                            ? Color.sage
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
                ? Tokens.accentWashStrong
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
                            ? Color.sage
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
                ? Tokens.accentWashStrong
                : Color.clear,
            in: RoundedRectangle(cornerRadius: 4)
        )
    }

    private var upcomingSection: some View {
        UpcomingSidebarSection(viewModel: viewModel)
    }

    private var settingsRow: some View {
        Button {
            viewModel.showSettings()
        } label: {
            HStack(spacing: Tokens.spacingSM) {
                Image(systemName: "gearshape")
                    .foregroundStyle(
                        viewModel.route == .settings
                            ? Color.sage
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
                ? Tokens.accentWashStrong
                : Color.clear,
            in: RoundedRectangle(cornerRadius: 4)
        )
    }

    // MARK: - Detail pane

    private var detailContent: some View {
        DetailContentView(viewModel: viewModel)
    }
}

// MARK: - Toolbar content

/// Extracted to keep `AppShellView` under the type-body-length limit.
private extension AppShellView {
    @ToolbarContentBuilder
    var homeToolbarItem: some ToolbarContent {
        ToolbarItem(placement: .navigation) {
            Button {
                viewModel.showHome()
            } label: {
                Image(systemName: "house")
            }
            .help("Home")
            .disabled(viewModel.isHome)
        }
    }

    /// The stateful Record affordance: a live recording indicator while
    /// recording, otherwise the idle "Record" button.
    @ViewBuilder
    var recordButton: some View {
        if viewModel.isRecording {
            RecordingToolbarButton(viewModel: viewModel)
                .disabled(viewModel.isOnRecordingPage)
        } else {
            Button {
                Task { await viewModel.startRecording() }
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: "record.circle")
                    Text("Record")
                }
            }
            .buttonStyle(ToolbarRecordButtonStyle(fill: .accentFill))
            .help("Start recording")
        }
    }
}

/// Extracted to keep `AppShellView` under the type-body-length limit.
/// Routes the detail pane based on `AppCore.route`.
private struct DetailContentView: View {
    let viewModel: AppShellViewModel

    var body: some View {
        switch viewModel.route {
        case .home:
            // Home paints its own paper background internally.
            HomeView(viewModel: viewModel.homeViewModel)

        case .recording:
            RecordingView(
                viewModel: viewModel.recordingViewModel
            )
            .background(Tokens.contentBackground)

        case .meetings:
            MeetingsSplitView(viewModel: viewModel)

        case let .event(key):
            EventPreviewView(
                viewModel: viewModel.eventPreviewViewModel(for: key)
            )
            .id(key)
            .background(Tokens.contentBackground)

        case .settings:
            SettingsView(viewModel: viewModel.settingsViewModel)

        case .onboarding:
            // Handled by the full-window takeover above; should not reach here.
            EmptyView()
        }
    }
}

/// Extracted to keep `AppShellView` under the type-body-length limit.
/// The upcoming-events sidebar section.
private struct UpcomingSidebarSection: View {
    let viewModel: AppShellViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("UPCOMING")
                .kicker()
                .foregroundStyle(.inkSecondary)
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
                        ? Tokens.accentWashStrong
                        : Color.clear,
                    in: RoundedRectangle(cornerRadius: 4)
                )
            }

            Divider()
                .padding(.vertical, Tokens.spacingSM)
        }
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
            .frame(minWidth: 126, idealWidth: 154, maxWidth: 420)

            // Stable outer container so HSplitView always sees the
            // same structural child — prevents the divider from
            // snapping back to idealWidth when the detail content
            // changes (selection, .id swap, or placeholder toggle).
            detailPane
                .frame(minWidth: 360, maxWidth: .infinity)
                .background(Tokens.contentBackground)
        }
    }

    private var detailPane: some View {
        ZStack {
            let selection = viewModel.meetingsSelection
            if selection.count == 1, let id = selection.first {
                MeetingDetailView(
                    viewModel: viewModel.meetingDetailViewModel(
                        for: id
                    )
                )
                .id(id)
            } else if selection.count > 1 {
                MultiSelectPlaceholder(
                    count: selection.count,
                    listViewModel: viewModel.meetingListViewModel
                )
            } else {
                ContentUnavailableView {
                    Label {
                        Text("No Meeting Selected")
                            .font(.serifHeadline)
                    } icon: {
                        Image(systemName: "quote.bubble")
                    }
                } description: {
                    Text(
                        "Select a meeting to see its transcript and details."
                    )
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }
}

/// Placeholder shown when more than one meeting is selected.
/// Displays a count and a Delete button that triggers the confirmation.
private struct MultiSelectPlaceholder: View {
    let count: Int
    let listViewModel: MeetingListViewModel

    var body: some View {
        ContentUnavailableView {
            Label {
                Text("\(count) Meetings Selected")
                    .font(.serifHeadline)
            } icon: {
                Image(systemName: "checkmark.circle")
            }
        } actions: {
            Button(role: .destructive) {
                listViewModel.requestDeleteSelection()
            } label: {
                Text("Delete \(count) Meetings")
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - Recording toolbar button (light alert style)

/// The toolbar recording button: light alert style with a pulsing dot
/// and "REC m:ss" label. Extracted to keep `AppShellView` under the
/// type-body-length limit.
private struct RecordingToolbarButton: View {
    let viewModel: AppShellViewModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var pulsing = false

    var body: some View {
        Button {
            viewModel.showRecording()
        } label: {
            HStack(spacing: 6) {
                Circle()
                    .fill(Color.signalRed)
                    .frame(width: 8, height: 8)
                    .opacity(pulsing ? 0.4 : 1.0)
                    .animation(
                        reduceMotion
                            ? nil
                            : .easeInOut(duration: 0.8)
                            .repeatForever(autoreverses: true),
                        value: pulsing
                    )

                Text("REC \(viewModel.recordingElapsedText)")
                    .font(.monoMetaMedium)
                    .contentTransition(.identity)
                    .animation(nil, value: viewModel.recordingElapsedText)
            }
            .padding(.horizontal, 16)
            .frame(height: 32)
        }
        .buttonStyle(LightAlertButtonStyle())
        .help("Go to recording")
        .animation(nil, value: viewModel.isRecording)
        .onAppear {
            guard !reduceMotion else { return }
            pulsing = true
        }
    }
}

// MARK: - Sidebar RECORDING NOW section

/// A sidebar section showing the in-progress recording's title with a
/// "Recording" subtitle. Tapping navigates to the recording pane.
private struct RecordingNowSection: View {
    let viewModel: AppShellViewModel

    private var isSelected: Bool {
        viewModel.route == .recording
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("RECORDING NOW")
                .kicker()
                .foregroundStyle(Color.inkSecondary)
                .padding(.horizontal, Tokens.spacingMD)
                .padding(.bottom, Tokens.spacingXS)

            Button {
                viewModel.showRecording()
            } label: {
                VStack(alignment: .leading, spacing: 2) {
                    Text(viewModel.recordingMeetingTitle)
                        .font(.body)
                        .foregroundStyle(Color.ink)
                        .lineLimit(1)

                    Text("Recording")
                        .font(.monoMeta)
                        .foregroundStyle(Color.inkSecondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.vertical, Tokens.spacingXS)
                .padding(.horizontal, Tokens.spacingSM)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .background(
                isSelected
                    ? Tokens.accentWashStrong
                    : Color.clear,
                in: RoundedRectangle(cornerRadius: 4)
            )

            Divider()
                .padding(.vertical, Tokens.spacingSM)
        }
    }
}

#if DEBUG
    #Preview("App Shell") {
        let core = try! PreviewAppCore.make() // swiftlint:disable:this force_try
        let viewModel = AppShellViewModel(core: core)
        AppShellView(viewModel: viewModel)
            .frame(width: 700, height: 500)
    }
#endif
