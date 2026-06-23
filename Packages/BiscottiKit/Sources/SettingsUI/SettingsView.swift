import AppCore
import AppKit
import Calendar
import DataStore
import DesignSystem
import Intelligence
import ModelManagementUI
import Permissions
import SwiftUI

/// In-window settings screen. General preferences, permissions overview
/// with inline request/grant actions, and calendar include/exclude.
public struct SettingsView: View {
    /// Internal (not private) so the cross-file extension in
    /// SettingsSystemAudioRow.swift can bind to it.
    @Bindable var viewModel: SettingsViewModel
    @State private var showAlertsHelp = false
    @State private var showManageModels = false

    public init(viewModel: SettingsViewModel) {
        self.viewModel = viewModel
    }

    /// Canonical section titles in display order. Each section's header
    /// is driven from this array (`sectionTitles[N]`), so reordering here
    /// reorders the rendered headers. Debug is appended in debug builds.
    static let sectionTitles = [
        "General",
        "Permissions",
        "Notifications",
        "AI Enhancements",
        "Calendars"
    ]

    /// Muted caption trailing the AI Enhancements header.
    static let aiEnhancementsHeaderCaption = "AI runs locally on your Mac."

    public var body: some View {
        ScrollView {
            // Sections in spec order (section 13.3)
            Form {
                generalSection
                permissionsSection
                notificationsSection
                aiEnhancementsSection
                calendarSection

                #if DEBUG
                    debugSection
                #endif
            }
            .formStyle(.grouped)
            .scrollContentBackground(.hidden)
            .padding(Tokens.spacingMD)
        }
        .frame(
            maxWidth: .infinity,
            maxHeight: .infinity,
            alignment: .topLeading
        )
        .background(Tokens.contentBackground)
        .task { await viewModel.load() }
    }

    // MARK: - General section

    private var generalSection: some View {
        Section(Self.sectionTitles[0]) {
            Toggle(
                "Launch at login",
                isOn: launchAtLoginBinding
            )
            VStack(alignment: .leading, spacing: Tokens.spacingXS) {
                Toggle(
                    "Exit app on window close",
                    isOn: exitOnWindowCloseBinding
                )
                Text("When off, closing the window keeps Biscotti running in the menu bar.")
                    .font(Tokens.metadataFont)
                    .foregroundStyle(Tokens.secondaryText)
            }
            Toggle(
                "Global shortcut to start recording (\u{2318}\u{21E7}R)",
                isOn: globalRecordShortcutBinding
            )
            VStack(alignment: .leading, spacing: Tokens.spacingXS) {
                Toggle(
                    "Stop Recording Automatically",
                    isOn: stopRecordingAutomaticallyBinding
                )
                Text("Stop recording when we detect your meeting has ended.")
                    .font(Tokens.metadataFont)
                    .foregroundStyle(Tokens.secondaryText)
            }
            Picker(
                "Show next meeting in menu bar",
                selection: menuBarLeadTimeBinding
            ) {
                ForEach(MenuBarLeadTime.allCases) { option in
                    Text(option.displayText).tag(option)
                }
            }
        }
    }

    private var launchAtLoginBinding: Binding<Bool> {
        Binding(
            get: { viewModel.launchAtLogin },
            set: { newValue in
                Task { await viewModel.setLaunchAtLogin(newValue) }
            }
        )
    }

    private var exitOnWindowCloseBinding: Binding<Bool> {
        Binding(
            get: { viewModel.exitOnWindowClose },
            set: { newValue in
                Task { await viewModel.setExitOnWindowClose(newValue) }
            }
        )
    }

    private var globalRecordShortcutBinding: Binding<Bool> {
        Binding(
            get: { viewModel.globalRecordShortcutEnabled },
            set: { newValue in
                Task { await viewModel.setGlobalRecordShortcut(newValue) }
            }
        )
    }

    private var stopRecordingAutomaticallyBinding: Binding<Bool> {
        Binding(
            get: { viewModel.stopRecordingAutomatically },
            set: { newValue in
                Task {
                    await viewModel.setStopRecordingAutomatically(newValue)
                }
            }
        )
    }

    private var menuBarLeadTimeBinding: Binding<MenuBarLeadTime> {
        Binding(
            get: { viewModel.menuBarLeadTime },
            set: { newValue in
                Task { await viewModel.setMenuBarLeadTime(newValue) }
            }
        )
    }

    // MARK: - Calendar section

    private var calendarSection: some View {
        Section(Self.sectionTitles[4]) {
            if viewModel.calendarState == .authorized {
                if viewModel.calendarGroups.isEmpty {
                    Text("No calendars found.")
                        .font(Tokens.metadataFont)
                        .foregroundStyle(Tokens.secondaryText)
                } else {
                    ForEach(viewModel.calendarGroups) { group in
                        Section(header: Text(group.sourceTitle)) {
                            ForEach(group.calendars) { cal in
                                calendarRow(cal)
                            }
                        }
                    }
                }
            } else {
                Text("Calendar access not granted.")
                    .font(Tokens.metadataFont)
                    .foregroundStyle(Tokens.secondaryText)
                permissionActionButton(
                    state: viewModel.calendarState,
                    kind: .calendar
                )
            }
        }
    }

    private func calendarRow(_ cal: CalendarInfo) -> some View {
        Toggle(isOn: calendarBinding(cal.id)) {
            HStack(spacing: Tokens.spacingSM) {
                Circle()
                    .fill(Color(hex: cal.colorHex))
                    .frame(width: 10, height: 10)
                Text(cal.title)
            }
        }
    }

    private func calendarBinding(_ id: String) -> Binding<Bool> {
        Binding(
            get: { viewModel.isCalendarEnabled(id) },
            set: { _ in Task { await viewModel.toggleCalendar(id) } }
        )
    }

    // MARK: - Permissions section

    private var permissionsSection: some View {
        Section(Self.sectionTitles[1]) {
            permissionRow(
                "Microphone", state: viewModel.microphoneState, kind: .microphone
            )
            systemAudioRow
            permissionRow(
                "Calendar", state: viewModel.calendarState, kind: .calendar
            )
            permissionRow(
                "Notifications", state: viewModel.notificationsState, kind: .notifications
            )
        }
    }

    private func permissionRow(
        _ label: String,
        state: PermissionState,
        kind: PermissionKind
    ) -> some View {
        HStack {
            Image(
                systemName: state == .authorized
                    ? "checkmark.circle.fill"
                    : "exclamationmark.triangle.fill"
            )
            .foregroundStyle(
                state == .authorized ? .sage : .warningOchre
            )

            Text(label)

            Spacer()

            Text(state.displayText)
                .font(Tokens.metadataFont)
                .foregroundStyle(Tokens.secondaryText)

            permissionActionButton(state: state, kind: kind)
        }
    }

    /// Shows the appropriate action button for a permission's current state:
    /// - `.notDetermined` -> "Request Access" (triggers the OS permission prompt)
    /// - `.denied` -> "Open Settings" (deep link to System Settings)
    /// - `.authorized` -> no button
    @ViewBuilder
    private func permissionActionButton(
        state: PermissionState,
        kind: PermissionKind
    ) -> some View {
        switch state {
        case .notDetermined:
            Button("Request Access") {
                Task { await viewModel.requestPermission(for: kind) }
            }
            .buttonStyle(.bordered)
            .controlSize(.small)

        case .denied:
            Button("Open Settings") {
                viewModel.openPermissionSettings(for: kind)
            }
            .buttonStyle(.bordered)
            .controlSize(.small)

        case .authorized:
            EmptyView()
        }
    }

    // MARK: - Debug section

    #if DEBUG
        private var debugSection: some View {
            Section("Debug") {
                Button {
                    viewModel.replayOnboarding()
                } label: {
                    Label("Replay Onboarding", systemImage: "arrow.counterclockwise")
                }
                .foregroundStyle(.sage)

                Button {
                    viewModel.clearSelectedModel()
                } label: {
                    Label("Clear Selected LLM", systemImage: "arrow.uturn.backward")
                }
                .foregroundStyle(.sage)
            }
        }
    #endif
}

// MARK: - AI Enhancements section

private extension SettingsView {
    var aiEnhancementsSection: some View {
        Section {
            VStack(alignment: .leading, spacing: Tokens.spacingXS) {
                Toggle(
                    "AI Analysis & Summary",
                    isOn: aiAnalysisEnabledBinding
                )
                .disabled(!viewModel.modelAvailable)
                Text(
                    "Generate a title and summary from the transcript, and guess the names of speakers from context."
                )
                .font(Tokens.metadataFont)
                .foregroundStyle(Tokens.secondaryText)
            }

            aiLanguageModelRow
        } header: {
            HStack {
                Text(Self.sectionTitles[3])
                Spacer()
                Text(Self.aiEnhancementsHeaderCaption)
                    .font(Tokens.metadataFont)
                    .foregroundStyle(Tokens.secondaryText)
            }
        }
        .sheet(isPresented: $showManageModels) {
            ManageModelsSheet(
                viewModel: ManageModelsViewModel(core: viewModel.appCore)
            )
        }
    }

    var aiLanguageModelRow: some View {
        HStack {
            VStack(alignment: .leading, spacing: Tokens.spacingXS) {
                Text("AI Language Model")
                Text("The AI model used to summarize meetings")
                    .font(Tokens.metadataFont)
                    .foregroundStyle(Tokens.secondaryText)
            }

            Spacer()

            if let displayName = viewModel.activeModelDisplayName {
                Text(displayName)
                    .font(Tokens.metadataFont)
                    .foregroundStyle(Tokens.secondaryText)
                Button("Manage") {
                    showManageModels = true
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            } else {
                Button("Download\u{2026}") {
                    showManageModels = true
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }
        }
    }

    var aiAnalysisEnabledBinding: Binding<Bool> {
        Binding(
            get: {
                viewModel.modelAvailable
                    ? viewModel.aiAnalysisEnabled
                    : false
            },
            set: { newValue in
                Task { await viewModel.setAIAnalysisEnabled(newValue) }
            }
        )
    }
}

// MARK: - Notifications section

private extension SettingsView {
    var notificationsSection: some View {
        Section(Self.sectionTitles[2]) {
            // Row 1: Monitor for Meetings
            VStack(alignment: .leading, spacing: Tokens.spacingXS) {
                Toggle(
                    "Monitor for Meetings",
                    isOn: monitorForMeetingsBinding
                )
                Text(
                    "Detect when an app starts using your microphone and offer to record. Nothing is recorded or processed unless you start recording."
                )
                .font(Tokens.metadataFont)
                .foregroundStyle(Tokens.secondaryText)
            }

            // Row 2: Calendar Event Notifications
            VStack(alignment: .leading, spacing: Tokens.spacingXS) {
                Picker(
                    "Calendar Event Notifications",
                    selection: calendarNotificationModeBinding
                ) {
                    ForEach(CalendarNotificationMode.allCases) { mode in
                        Text(mode.displayText).tag(mode)
                    }
                }
                .disabled(viewModel.calendarNotificationsDisabled)

                if viewModel.calendarNotificationsDisabled {
                    requiresCalendarAccessBadge
                }

                Text(
                    "Show a notification to record and join when a calendar event starts."
                )
                .font(Tokens.metadataFont)
                .foregroundStyle(Tokens.secondaryText)
            }

            // Row 3: Notifications Stay Visible (only when alertStyle == .banner)
            if viewModel.showStayVisibleRow {
                stayVisibleRow
            }
        }
        .onReceive(
            NotificationCenter.default.publisher(
                for: NSApplication.didBecomeActiveNotification
            )
        ) { _ in
            Task { await viewModel.refreshAlertStyle() }
        }
        .sheet(isPresented: $showAlertsHelp) {
            AlertsHelpSheet(viewModel: viewModel)
        }
    }

    var stayVisibleRow: some View {
        HStack {
            VStack(alignment: .leading, spacing: Tokens.spacingXS) {
                Text("Notifications Stay Visible")
                Text(
                    "Make notifications stay open until clicked or dismissed."
                )
                .font(Tokens.metadataFont)
                .foregroundStyle(Tokens.secondaryText)
            }
            Spacer()
            Button("Enable") {
                showAlertsHelp = true
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
        }
    }

    var requiresCalendarAccessBadge: some View {
        HStack(spacing: 4) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.caption2)
            Text("Requires Calendar Access")
                .font(.caption)
        }
        .foregroundStyle(Tokens.warningChipText)
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
        .background(
            Capsule().fill(Tokens.warningChipFill)
        )
    }

    var monitorForMeetingsBinding: Binding<Bool> {
        Binding(
            get: { viewModel.monitorForMeetings },
            set: { newValue in
                Task { await viewModel.setMonitorForMeetings(newValue) }
            }
        )
    }

    var calendarNotificationModeBinding: Binding<CalendarNotificationMode> {
        Binding(
            get: {
                viewModel.calendarNotificationsDisabled
                    ? .never
                    : viewModel.calendarNotificationMode
            },
            set: { newValue in
                Task {
                    await viewModel.setCalendarNotificationMode(newValue)
                }
            }
        )
    }
}

// Color(hex:) initializer is in DesignSystem/CalendarContextBlock.swift

#if DEBUG
    #Preview("Settings") {
        let core = try! PreviewAppCore.make() // swiftlint:disable:this force_try
        let viewModel = SettingsViewModel(core: core)
        SettingsView(viewModel: viewModel)
            .frame(width: 500, height: 600)
    }
#endif
