import DataStore
import DesignSystem
import SwiftUI

/// A small icon button that sends the meeting to a third-party app.
///
/// Rendered at 17 pt as a template image with the same style as the
/// Copy button in the tab bar: `.borderless`, `.controlSize(.small)`,
/// `.foregroundStyle(.inkSecondary)`.
struct SendToButton: View {
    let destination: ExportDestination
    let enabled: Bool
    let action: () -> Void

    private var iconKind: ExportIcons.Kind {
        switch destination {
        case .obsidian: .obsidian
        case .bear: .bear
        case .appleNotes: .appleNotes
        }
    }

    private var tooltip: String {
        enabled ? "Send to \(destination.displayName)" : "Nothing to send yet"
    }

    var body: some View {
        Button(action: action) {
            Image(nsImage: ExportIcons.image(iconKind))
                .resizable()
                .frame(width: 17, height: 17)
        }
        .buttonStyle(.borderless)
        .controlSize(.small)
        .foregroundStyle(.inkSecondary)
        .disabled(!enabled)
        .help(tooltip)
        .accessibilityLabel(tooltip)
    }
}
