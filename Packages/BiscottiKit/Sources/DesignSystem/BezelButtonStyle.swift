import SwiftUI

/// Small neutral bezel button -- the light-chrome sibling of
/// `LightAlertButtonStyle`. Used for "Go to Meeting", "Show in Finder",
/// and similar non-prominent actions.
///
/// - Label: system 13 medium, `Color.ink`, horizontal padding 12, height 28.
/// - Background: `elevatedFill` in `buttonRadius` (8) rounded rect.
/// - Border: 0.5pt `controlStroke`.
/// - Shadow: `controlShadow`, radius 0.75, y 1.
/// - Pressed: `neutralChip` overlay. Disabled: opacity 0.5.
public struct BezelButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled

    public init() {}

    public func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 13, weight: .medium))
            .foregroundStyle(Color.ink)
            .lineLimit(1)
            .padding(.horizontal, 12)
            .frame(height: 28)
            .background(
                RoundedRectangle(cornerRadius: Tokens.buttonRadius)
                    .fill(Color.elevatedFill)
            )
            .overlay(
                RoundedRectangle(cornerRadius: Tokens.buttonRadius)
                    .fill(configuration.isPressed ? Color.neutralChip : .clear)
            )
            .overlay(
                RoundedRectangle(cornerRadius: Tokens.buttonRadius)
                    .strokeBorder(Color.controlStroke, lineWidth: 0.5)
            )
            .shadow(color: .controlShadow, radius: 0.75, x: 0, y: 1)
            .opacity(isEnabled ? 1.0 : 0.5)
    }
}

#if DEBUG
    #Preview("BezelButtonStyle") {
        HStack(spacing: 16) {
            Button("Go to Meeting") {}
                .buttonStyle(BezelButtonStyle())
            Button("Show in Finder") {}
                .buttonStyle(BezelButtonStyle())
            Button("Disabled") {}
                .buttonStyle(BezelButtonStyle())
                .disabled(true)
        }
        .padding()
        .background(Tokens.contentBackground)
    }
#endif
