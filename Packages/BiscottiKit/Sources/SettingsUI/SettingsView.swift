import AppCore
import AppKit
import Calendar
import DataStore
import DesignSystem
import Permissions
import SwiftUI

/// In-window settings screen. General preferences, permissions overview
/// with inline request/grant actions, and calendar include/exclude.
public struct SettingsView: View {
    @Bindable private var viewModel: SettingsViewModel

    public init(viewModel: SettingsViewModel) {
        self.viewModel = viewModel
    }

    public var body: some View {
        ScrollView {
            Form {
                // General
                generalSection

                // Permissions (above Calendars per user feedback)
                permissionsSection

                // Calendars (last)
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
        Section("General") {
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
        Section("Calendars") {
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
        Section("Permissions") {
            permissionRow(
                "Microphone", state: viewModel.microphoneState, kind: .microphone
            )
            permissionRow(
                "System Audio", state: viewModel.systemAudioState, kind: .systemAudio
            )
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
            }
        }
    #endif
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
