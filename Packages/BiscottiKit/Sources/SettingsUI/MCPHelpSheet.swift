import DesignSystem
import MCPServer
import SwiftUI

/// How-to-connect sheet for the MCP row: the endpoint URL with a Copy
/// button, a paste-ready JSON snippet for MCP clients, and the exposure
/// warning (functional spec §2.1). Same treatment as `AlertsHelpSheet`.
struct MCPHelpSheet: View {
    @Environment(\.dismiss) private var dismiss

    /// The paste-ready MCP client configuration snippet. The port is fixed
    /// (compile-time constant), which is what makes this copy-pasteable.
    static let configSnippet =
        "{ \"mcpServers\": { \"biscotti\": { \"url\": \"\(MCPServerConfiguration.endpointURL.absoluteString)\" } } }"

    var body: some View {
        VStack(alignment: .leading, spacing: Tokens.spacingMD) {
            Text("How to Connect")
                .font(.headline)

            Text(
                "Add Biscotti to any MCP-capable agent (Claude Desktop, Claude Code, Cursor, \u{2026}) with this configuration:"
            )

            Text(Self.configSnippet)
                .font(.system(.caption, design: .monospaced))
                .textSelection(.enabled)
                .padding(Tokens.spacingSM)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(
                    RoundedRectangle(cornerRadius: Tokens.buttonRadius)
                        .fill(Tokens.neutralChip)
                )

            HStack(spacing: Tokens.spacingSM) {
                Text(MCPServerConfiguration.endpointURL.absoluteString)
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(Tokens.secondaryText)
                MCPEndpointCopyButton(url: MCPServerConfiguration.endpointURL)
                Spacer()
            }

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
