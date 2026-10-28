import DesignSystem
import LiveTranscriptModel
import SwiftUI

/// The drawer footer's language menu: "English" / "Best quality" and
/// "Detect language" / "Finds the language once, then keeps it", the current
/// choice checked. Its label shows the detected language once Detect has
/// found it.
struct LanguageMenu: View {
    let viewModel: RecordingViewModel

    var body: some View {
        let current = viewModel.liveLanguage
        Menu {
            ForEach(viewModel.languageChoices) { choice in
                Toggle(isOn: Binding(
                    get: { choice.language == current },
                    set: { isOn in
                        guard isOn else { return }
                        Task { await viewModel.setLanguage(choice.language) }
                    }
                )) {
                    Text(choice.title)
                    if let subtitle = choice.subtitle {
                        Text(subtitle)
                    }
                }
            }
        } label: {
            HStack(spacing: Tokens.spacingXS + 2) {
                Image(systemName: "character.bubble")
                    .font(.system(size: 12))
                Text(viewModel.languageMenuTitle)
                    .font(.system(size: 13))
                    .lineLimit(1)
                Image(systemName: "chevron.down")
                    .font(.system(size: 9, weight: .semibold))
            }
            // 13 pt text on the white card: inkSecondary reaches only 3.8:1.
            .foregroundStyle(.inkSecondaryLegible)
            .padding(.horizontal, Tokens.spacingSM)
            .frame(height: 28)
            .contentShape(Rectangle())
        }
        .menuStyle(.button)
        .buttonStyle(LanguageMenuButtonStyle())
        .menuIndicator(.hidden)
        .fixedSize()
        .help("Live transcript language")
        .accessibilityLabel("Live transcript language")
        .accessibilityValue(viewModel.languageMenuTitle)
    }
}

private struct LanguageMenuButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        HoverHighlight(isPressed: configuration.isPressed) { configuration.label }
    }
}

/// A rounded `neutralChip` fill while hovered or pressed.
struct HoverHighlight<Content: View>: View {
    let isPressed: Bool
    @ViewBuilder let content: Content
    @State private var isHovered = false

    var body: some View {
        content
            .background {
                RoundedRectangle(cornerRadius: Tokens.buttonRadius, style: .continuous)
                    .fill(isHovered || isPressed ? Tokens.neutralChip : Color.clear)
            }
            .onHover { isHovered = $0 }
    }
}
