import AppKit
import DesignSystem
import MCPServer
import SwiftUI

/// How-to-connect sheet for the MCP row (functional spec §2.1): the
/// endpoint URL with a Copy button at readable size, a link out to the
/// per-client connection guide, and the exposure warning. Same treatment
/// as `AlertsHelpSheet`. There is deliberately no JSON config snippet —
/// client configs are inconsistent across agents, so per-client
/// instructions live in the guide instead.
struct MCPHelpSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL

    /// The connection guide shipped in the repo (`App/ConnectingMCP.md`),
    /// read on GitHub.
    static let guideURL = URL(
        string: "https://github.com/scosman/Biscotti/blob/main/App/ConnectingMCP.md"
    )!

    var body: some View {
        VStack(alignment: .leading, spacing: Tokens.spacingMD) {
            Text("Connect to MCP")
                .font(.headline)

            Text(
                "Add Biscotti MCP to any agent to chat with your meeting notes."
            )

            VStack(alignment: .leading, spacing: Tokens.spacingXS) {
                Text("MCP Server URL")
                    .font(.subheadline.weight(.semibold))
                HStack(spacing: Tokens.spacingSM) {
                    Text(MCPServerConfiguration.endpointURL.absoluteString)
                        .font(.system(.callout, design: .monospaced))
                        .textSelection(.enabled)
                    MCPEndpointCopyButton(url: MCPServerConfiguration.endpointURL)
                    Spacer()
                }
            }

            Button("How to connect to common agents (Claude, Cursor, etc)") {
                openURL(Self.guideURL)
            }
            .buttonStyle(.link)
            .tint(.sage)

            Text(
                "Any app on this Mac can read your meetings while this is on. "
                    + "Nothing leaves your machine unless the agent you connect "
                    + "sends it somewhere."
            )
            .font(Tokens.metadataFont)
            .foregroundStyle(Tokens.secondaryText)

            HStack {
                Spacer()
                Button("Done") {
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
                .tint(.sage)
            }
        }
        .padding(Tokens.spacingMD * 1.5)
        .frame(width: 400)
    }
}

/// Endpoint Copy button with transient "Copied" feedback (1.5 s revert), the
/// same treatment as the transcript Copy button in MeetingDetailUI. Used by
/// the How-to-connect sheet.
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
