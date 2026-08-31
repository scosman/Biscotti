import DesignSystem
import MCPServer
import SwiftUI

// MARK: - MCP row (extracted for type_body_length)

extension SettingsView {
    /// Subtitle shown under the MCP toggle whenever the server is not
    /// starting/failed (functional spec §2.1).
    static let mcpSubtitle = "Chat with your meeting notes in any agent."

    /// Toggle-on confirmation alert copy (functional spec §2.1).
    /// Verbatim-identity policy: these statics == the spec text.
    static let mcpConfirmTitle = "Allow local apps to read your meetings?"

    static let mcpConfirmMessage =
        "While MCP is on, any app on this Mac can read your meeting notes, "
            + "transcripts, and summaries. Nothing leaves your Mac unless an agent "
            + "you connect sends it somewhere."

    static let mcpConfirmCancelTitle = "Cancel"

    static let mcpConfirmTurnOnTitle = "Turn On"

    /// The MCP settings row, last in the General section: the toggle holds
    /// the user's intent (`mcpServerEnabled`), the caption below renders the
    /// server's live state (`mcpServerState`). The toggle stays on after a
    /// start failure — intent is preserved, the caption explains (§2.3).
    /// The endpoint URL and its Copy button live only in the help sheet.
    var mcpRow: some View {
        VStack(alignment: .leading, spacing: Tokens.spacingXS) {
            Toggle("MCP", isOn: mcpEnabledBinding)
                .disabled(isMCPStarting)

            switch viewModel.mcpServerState {
            case .stopped:
                mcpSubtitleText

            case .starting:
                Text("Starting\u{2026}")
                    .font(Tokens.metadataFont)
                    .foregroundStyle(Tokens.secondaryText)

            case .running:
                HStack(alignment: .firstTextBaseline, spacing: Tokens.spacingSM) {
                    mcpSubtitleText
                    // Colored directly on the label, not via `.tint`: link
                    // and Form-row styling resolve their own (system blue)
                    // accent and ignore a tint set at this scope.
                    Button {
                        showMCPHelp = true
                    } label: {
                        Text("How to connect")
                            .foregroundStyle(.sage)
                    }
                    .buttonStyle(.borderless)
                    .controlSize(.small)
                }

            case let .failed(error):
                Text(error.userMessage)
                    .font(Tokens.metadataFont)
                    .foregroundStyle(Tokens.signalRedText)
                Button("Retry") {
                    Task { await viewModel.retryMCPServer() }
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }
        }
        .sheet(isPresented: $showMCPHelp) {
            MCPHelpSheet()
        }
        .alert(Self.mcpConfirmTitle, isPresented: $showMCPConfirm) {
            Button(Self.mcpConfirmCancelTitle, role: .cancel) {}
            Button(Self.mcpConfirmTurnOnTitle) {
                Task { await viewModel.setMCPServerEnabled(true) }
            }
            .keyboardShortcut(.defaultAction)
        } message: {
            Text(Self.mcpConfirmMessage)
        }
    }

    private var mcpSubtitleText: some View {
        Text(Self.mcpSubtitle)
            .font(Tokens.metadataFont)
            .foregroundStyle(Tokens.secondaryText)
    }

    /// Intent binding: reads/writes the persisted setting; AppCore reacts to
    /// the posted notification and drives the live state the caption shows.
    /// Turning on does not enable directly — it presents the confirmation
    /// alert (§2.1); only that alert's Turn On button enables. Cancel leaves
    /// the stored intent off, so the toggle (whose `get` reads it) snaps
    /// back. Turning off is unchanged: immediate disable, no alert.
    var mcpEnabledBinding: Binding<Bool> {
        Binding(
            get: { viewModel.mcpServerEnabled },
            set: { newValue in
                if newValue {
                    showMCPConfirm = true
                } else {
                    Task { await viewModel.setMCPServerEnabled(false) }
                }
            }
        )
    }

    var isMCPStarting: Bool {
        if case .starting = viewModel.mcpServerState { return true }
        return false
    }
}
