import AppShellUI
import SwiftUI

/// View > Show / Hide Live Transcript (⌘T), after the sidebar item.
struct LiveTranscriptCommands: Commands {
    let model: LiveCommandModel

    var body: some Commands {
        CommandGroup(after: .sidebar) {
            LiveTranscriptMenuItem(model: model)
        }
    }
}

/// Reads the model in a view `body`, where observation tracking is reliable
/// (scene and command builders do not track it reliably).
private struct LiveTranscriptMenuItem: View {
    let model: LiveCommandModel

    var body: some View {
        Button(model.title) {
            model.toggle()
        }
        .keyboardShortcut("t", modifiers: .command)
        .disabled(!model.isEnabled)
    }
}
