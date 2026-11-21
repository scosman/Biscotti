import AppCore
import AppKit
import DesignSystem
import SwiftUI

/// Every permission, same row, same button. Used in Settings
/// and in the launch prompt. "Grant…" asks macOS when it still can and
/// otherwise opens the right System Settings pane. Statuses refresh every
/// 2 seconds and when Biscotti comes back to the front, because macOS sends
/// no notice when a permission changes in System Settings.
public struct PermissionList: View {
    let core: AppCore
    /// Limit to these permissions (the launch prompt); nil shows all.
    let only: [AppPermission]?
    /// Statuses as of the last poll. Rows read these, so a poll updates a
    /// row's text without rebuilding it (the Grant button keeps its focus).
    @State private var statuses: [AppPermission: AppPermissionStatus] = [:]

    public init(core: AppCore, only: [AppPermission]? = nil) {
        self.core = core
        self.only = only
    }

    public var body: some View {
        let permissions = only ?? AppPermission.allCases
        VStack(alignment: .leading, spacing: Tokens.spacingSM) {
            ForEach(permissions) { permission in
                row(permission)
            }
        }
        .task {
            while !Task.isCancelled {
                await refresh(permissions)
                try? await Task.sleep(for: .seconds(2))
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            Task { await refresh(permissions) }
        }
    }

    /// Accessibility isn't observable, so statuses are polled into state.
    private func refresh(_ permissions: [AppPermission]) async {
        await core.refreshAllPermissions()
        let latest = Dictionary(uniqueKeysWithValues: permissions.map { ($0, core.status(of: $0)) })
        if latest != statuses { statuses = latest }
    }

    private func row(_ permission: AppPermission) -> some View {
        let status = statuses[permission] ?? core.status(of: permission)
        return HStack(alignment: .firstTextBaseline) {
            Image(systemName: status == .granted ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                .foregroundStyle(status == .granted ? .sage : .warningOchre)
            VStack(alignment: .leading, spacing: 2) {
                Text(permission.title)
                Text(permission.purpose)
                    .font(Tokens.metadataFont)
                    .foregroundStyle(Tokens.secondaryText)
            }
            Spacer()
            Text(status.title)
                .font(Tokens.metadataFont)
                .foregroundStyle(Tokens.secondaryText)
            if status != .granted {
                Button("Grant\u{2026}") {
                    Task {
                        await core.grant(permission)
                        await refresh(only ?? AppPermission.allCases)
                    }
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .help(status == .blocked
                    ? "Opens System Settings, where you can turn it on for Biscotti."
                    : "Shows the macOS permission prompt.")
            }
        }
    }
}

/// Shown at launch when something Biscotti needs is missing.
public struct PermissionsPromptSheet: View {
    let core: AppCore
    let permissions: [AppPermission]
    let onDone: () -> Void

    public init(core: AppCore, permissions: [AppPermission], onDone: @escaping () -> Void) {
        self.core = core
        self.permissions = permissions
        self.onDone = onDone
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: Tokens.spacingMD) {
            Text("Biscotti needs a few permissions")
                .font(.title3.weight(.semibold))
            Text("Click Grant\u{2026} next to each. If macOS has already asked, it opens System Settings instead, where you switch Biscotti on.")
                .font(Tokens.metadataFont)
                .foregroundStyle(Tokens.secondaryText)
            PermissionList(core: core, only: permissions)
            Text("You can change these any time in Settings \u{2192} Permissions.")
                .font(Tokens.metadataFont)
                .foregroundStyle(Tokens.secondaryText)
            HStack {
                Spacer()
                Button("Done", action: onDone)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(Tokens.spacingLG)
        .frame(width: 520)
    }
}
