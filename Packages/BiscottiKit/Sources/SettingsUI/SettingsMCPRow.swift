import DesignSystem
import MCPServer
import SwiftUI

// MARK: - MCP row (extracted for type_body_length)

extension SettingsView {
    /// Subtitle shown under the MCP toggle whenever the server is not
    /// starting/failed (functional spec §2.1).
    static let mcpSubtitle = "Chat with your meeting notes in any agent."

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
                    Button("How to connect") {
                        showMCPHelp = true
                    }
                    .buttonStyle(.link)
                    .controlSize(.small)
                    .tint(.sage)
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
    }

    private var mcpSubtitleText: some View {
        Text(Self.mcpSubtitle)
            .font(Tokens.metadataFont)
            .foregroundStyle(Tokens.secondaryText)
    }

    /// Intent binding: reads/writes the persisted setting; AppCore reacts to
    /// the posted notification and drives the live state the caption shows.
    var mcpEnabledBinding: Binding<Bool> {
        Binding(
            get: { viewModel.mcpServerEnabled },
            set: { newValue in
                Task { await viewModel.setMCPServerEnabled(newValue) }
            }
        )
    }

    var isMCPStarting: Bool {
        if case .starting = viewModel.mcpServerState { return true }
        return false
    }
}
