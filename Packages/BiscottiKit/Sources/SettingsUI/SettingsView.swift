import AppCore
import AppKit
import Calendar
import DesignSystem
import Permissions
import SwiftUI

/// Settings screen. Hosted in the standard macOS Settings window (Cmd+,).
/// General preferences, permissions overview with inline request/grant
/// actions, and calendar include/exclude.
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
            }
            .formStyle(.grouped)
            .padding(Tokens.spacingMD)
        }
        .frame(
            maxWidth: .infinity,
            maxHeight: .infinity,
            alignment: .topLeading
        )
        .task { await viewModel.load() }
    }

    // MARK: - General section

    private var generalSection: some View {
        Section("General") {
            Toggle(
                "Launch at login",
                isOn: launchAtLoginBinding
            )
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
                state == .authorized ? .green : .orange
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
}

// Color(hex:) initializer is in DesignSystem/CalendarContextBlock.swift

#Preview("Settings") {
    let core = try! PreviewAppCore.make() // swiftlint:disable:this force_try
    let viewModel = SettingsViewModel(core: core)
    SettingsView(viewModel: viewModel)
        .frame(width: 500, height: 600)
}
