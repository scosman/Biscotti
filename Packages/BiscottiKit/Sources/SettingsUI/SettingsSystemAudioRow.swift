import DesignSystem
import Permissions
import SwiftUI

// MARK: - System Audio row (extracted for type_body_length)

extension SettingsView {
    // MARK: - System Audio row (dedicated 4-state)

    var systemAudioRow: some View {
        HStack {
            Image(
                systemName: viewModel.systemAudioState == .approved
                    ? "checkmark.circle.fill"
                    : "exclamationmark.triangle.fill"
            )
            .foregroundStyle(
                viewModel.systemAudioState == .approved ? .sage : .warningOchre
            )

            Text("System Audio")

            Spacer()

            if viewModel.isValidatingSystemAudio {
                Text("Validating\u{2026}")
                    .font(Tokens.metadataFont)
                    .foregroundStyle(Tokens.secondaryText)
                ProgressView()
                    .controlSize(.small)
            } else {
                Text(systemAudioStatusText)
                    .font(Tokens.metadataFont)
                    .foregroundStyle(Tokens.secondaryText)

                systemAudioActions
            }
        }
        .fixPermissionsAlert(
            isPresented: $viewModel.showFixPermissionsAlert,
            title: SystemAudioPermissionState.fixPermissionsAlertTitle,
            body: SystemAudioPermissionState.fixPermissionsAlertBody,
            onOpenSettings: { viewModel.openSystemAudioSettings() }
        )
    }

    @ViewBuilder
    var systemAudioActions: some View {
        switch viewModel.systemAudioState {
        case .notRequested:
            Button("Request Access") {
                Task { await viewModel.requestSystemAudio() }
            }
            .buttonStyle(.bordered)
            .controlSize(.small)

        case .requestedNotVerified:
            HStack(spacing: Tokens.spacingXS) {
                Button("Retry") {
                    Task { await viewModel.requestSystemAudio() }
                }
                .buttonStyle(.bordered)
                .controlSize(.small)

                Button("Fix permissions") {
                    viewModel.showFixPermissionsAlert = true
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }

        case .approved:
            Button("Validate") {
                Task { await viewModel.requestSystemAudio() }
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
        }
    }

    /// Status text for the system-audio row. Uses "Granted checkmark" for
    /// the approved state (per ui_design.md section 1), and falls through
    /// to `displayText` for the other states.
    var systemAudioStatusText: String {
        switch viewModel.systemAudioState {
        case .approved: "Granted \u{2713}"
        case .notRequested, .requestedNotVerified:
            viewModel.systemAudioState.displayText
        }
    }
}
