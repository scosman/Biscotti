import AppCore
import AppKit
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

    /// Bound to the custom search `TextField` in the toolbar. Two-way synced
    /// with AppCore's `meetingsQuery` via `.onChange` to avoid feedback loops.
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
                .background(Tokens.contentBackground)
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
                        .disabled(viewModel.isHome)
                    }

                    // Custom trailing group: search field + Record button.
                    // Native `.searchable` always anchors to the trailing edge,
                    // making it impossible to place a button to its right. We use
                    // a custom TextField styled as a search field so the Record
                    // button can sit to its right at the toolbar's trailing edge.
                    ToolbarItemGroup(placement: .primaryAction) {
                        HStack(spacing: 4) {
                            Image(systemName: "magnifyingglass")
                                .foregroundStyle(.inkSecondary)
                                .font(.body)
                            TextField("Search", text: $searchText)
                                .textFieldStyle(.plain)
                                .font(.body)
                                .frame(width: 160)
                                .background(SearchFieldFocuser(
                                    token: viewModel.searchFocusToken
                                ))
                            if !searchText.isEmpty {
                                Button {
                                    searchText = ""
                                } label: {
                                    Image(systemName: "xmark.circle.fill")
                                        .foregroundStyle(.inkSecondary)
                                        .font(.caption)
                                }
                                .buttonStyle(.plain)
                            }
                        }
                        .padding(.vertical, 4)
                        .padding(.horizontal, 6)
                        .background(Color.neutralChip)
                        .clipShape(RoundedRectangle(cornerRadius: 6))
                        .fixedSize()

                        if viewModel.isRecording {
                            RecordingToolbarButton(viewModel: viewModel)
                        } else {
                            Button {
                                Task { await viewModel.startRecording() }
                            } label: {
                                HStack(spacing: 4) {
                                    Image(systemName: "record.circle")
                                    Text("Record")
                                }
                            }
                            .buttonStyle(
                                ToolbarRecordButtonStyle(fill: .sage)
                            )
                            .help("Start recording")
                        }
                    }
                }
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
        .background(Color.wall.ignoresSafeArea())
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
            .frame(minWidth: 180, idealWidth: 220, maxWidth: 420)

            Group {
                if let id = viewModel.meetingsSelection {
                    MeetingDetailView(
                        viewModel: viewModel.meetingDetailViewModel(for: id)
                    )
                    .id(id)
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
            .frame(minWidth: 360, maxWidth: .infinity)
            .background(Tokens.contentBackground)
        }
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
            .frame(height: 34)
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
            .padding(.horizontal, Tokens.spacingSM)

            Divider()
                .padding(.vertical, Tokens.spacingSM)
        }
    }
}

// MARK: - Search field focus helper (AppKit first-responder)

/// An invisible `NSViewRepresentable` placed as a `.background()` on the
/// toolbar search `TextField`. When `token` changes (incremented by
/// `AppCore.focusSearch()`), it walks up from its own `NSView` to find
/// the hosting `NSTextField` and makes it the window's first responder.
///
/// SwiftUI's `@FocusState` is unreliable for `TextField`s hosted inside
/// `ToolbarItemGroup` on macOS (the toolbar's NSToolbarItemViewer is in
/// a separate hosting hierarchy). This uses AppKit's `makeFirstResponder`
/// directly, which always works regardless of hosting context.
private struct SearchFieldFocuser: NSViewRepresentable {
    let token: UInt

    func makeNSView(context _: Context) -> FocuserView {
        FocuserView()
    }

    func updateNSView(_ nsView: FocuserView, context _: Context) {
        guard token != nsView.lastToken else { return }
        nsView.lastToken = token
        // Skip the initial (token == 0) to avoid stealing focus on appear.
        guard token > 0 else { return }
        // Defer to the next run-loop pass so the view hierarchy is settled.
        DispatchQueue.main.async {
            nsView.focusNearestTextField()
        }
    }

    final class FocuserView: NSView {
        var lastToken: UInt = 0

        /// Walks up the view hierarchy from this invisible view to find
        /// the nearest `NSTextField` and makes it the first responder.
        func focusNearestTextField() {
            // Walk up a few levels looking for an editable NSTextField
            // in the subtree. The SwiftUI TextField's backing NSTextField
            // is typically a sibling or close ancestor-subtree peer.
            var ancestor: NSView? = superview
            for _ in 0 ..< 10 {
                guard let current = ancestor else { break }
                if let found = firstEditableTextField(in: current) {
                    found.window?.makeFirstResponder(found)
                    return
                }
                ancestor = current.superview
            }
        }

        /// Depth-first search for the first editable `NSTextField` in
        /// the given view's subtree.
        private func firstEditableTextField(
            in view: NSView
        ) -> NSTextField? {
            for subview in view.subviews {
                if let textField = subview as? NSTextField,
                   textField.isEditable
                {
                    return textField
                }
                if let found = firstEditableTextField(in: subview) {
                    return found
                }
            }
            return nil
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
