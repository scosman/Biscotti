import DesignSystem
import MCPServer
import SwiftUI

/// The MCP port field, shown under the toggle while MCP is on, so this
/// build and upstream Biscotti can run side by side. Commits on Return or
/// when focus leaves; a running or failed server restarts on the new port.
struct MCPPortField: View {
    let viewModel: SettingsViewModel

    @State private var text = ""
    @State private var isInvalid = false
    @FocusState private var isFocused: Bool

    static let invalidMessage = "Enter a port from 1024 to 65535."

    var body: some View {
        VStack(alignment: .leading, spacing: Tokens.spacingXS) {
            HStack(spacing: Tokens.spacingSM) {
                Text("Port")
                TextField(
                    "Port",
                    text: $text,
                    prompt: Text(String(MCPServerConfiguration.defaultPort))
                )
                .labelsHidden()
                .textFieldStyle(.roundedBorder)
                .monospacedDigit()
                .frame(width: 72)
                .focused($isFocused)
                .onSubmit(commit)
            }

            if isInvalid {
                Text(Self.invalidMessage)
                    .font(Tokens.metadataFont)
                    .foregroundStyle(Tokens.signalRedText)
            }
        }
        .onAppear { text = String(viewModel.mcpServerPort) }
        .onChange(of: viewModel.mcpServerPort) { _, port in
            text = String(port)
        }
        .onChange(of: isFocused) { _, focused in
            if !focused {
                commit()
            }
        }
    }

    private func commit() {
        guard let port = SettingsViewModel.mcpPort(fromText: text) else {
            isInvalid = true
            return
        }
        isInvalid = false
        guard port != viewModel.mcpServerPort else { return }
        Task { await viewModel.setMCPServerPort(port) }
    }
}
