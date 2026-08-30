import AppKit
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
    var mcpRow: some View {
        VStack(alignment: .leading, spacing: Tokens.spacingXS) {
            Toggle("MCP", isOn: mcpEnabledBinding)
                .disabled(isMCPStarting)

            switch viewModel.mcpServerState {
            case .stopped:
                Text(Self.mcpSubtitle)
                    .font(Tokens.metadataFont)
                    .foregroundStyle(Tokens.secondaryText)

            case .starting:
                Text("Starting\u{2026}")
                    .font(Tokens.metadataFont)
                    .foregroundStyle(Tokens.secondaryText)

            case let .running(url):
                Text(Self.mcpSubtitle)
                    .font(Tokens.metadataFont)
                    .foregroundStyle(Tokens.secondaryText)
                HStack(spacing: Tokens.spacingSM) {
                    Text(url.absoluteString)
                        .font(.system(.caption, design: .monospaced))
                        .foregroundStyle(Tokens.secondaryText)
                    MCPEndpointCopyButton(url: url)
                    Button("How to connect") {
                        showMCPHelp = true
                    }
                    .buttonStyle(.link)
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

/// Endpoint Copy button with transient "Copied" feedback (1.5 s revert), the
/// same treatment as the transcript Copy button in MeetingDetailUI. Shared by
/// the MCP settings row and the How-to-connect sheet.
struct MCPEndpointCopyButton: View {
    let url: URL

    @State private var didCopy = false
    @State private var copyResetTask: Task<Void, Never>?

    var body: some View {
        Button {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(
                url.absoluteString, forType: .string
            )
            didCopy = true
            copyResetTask?.cancel()
            copyResetTask = Task {
                try? await Task.sleep(for: .seconds(1.5))
                guard !Task.isCancelled else { return }
                didCopy = false
            }
        } label: {
            Text(didCopy ? "Copied" : "Copy")
                .transaction { $0.animation = nil }
        }
        .buttonStyle(.borderless)
        .controlSize(.small)
        .foregroundStyle(didCopy ? .sage : .inkSecondary)
    }
}
