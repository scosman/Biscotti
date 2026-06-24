import SwiftUI

/// Filled accent button style for the hero row's "Join & Record" / "Record" button.
///
/// Accent fill, white 13.5pt semibold label, height 32, radius 8, subtle top
/// highlight, pressed = dim. Custom style to avoid `.borderedProminent` default
/// metrics while keeping a native feel.
public struct JoinRecordButtonStyle: ButtonStyle {
    public init() {}

    public func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(Tokens.joinButtonLabel)
            .foregroundStyle(.white)
            .padding(.horizontal, 14)
            .frame(height: 32)
            .background(
                RoundedRectangle(cornerRadius: Tokens.buttonRadius)
                    .fill(Color.accentFill)
                    .overlay(alignment: .top) {
                        // Subtle top highlight
                        RoundedRectangle(cornerRadius: Tokens.buttonRadius)
                            .fill(
                                LinearGradient(
                                    colors: [.white.opacity(0.15), .clear],
                                    startPoint: .top,
                                    endPoint: .center
                                )
                            )
                    }
            )
            .clipShape(RoundedRectangle(cornerRadius: Tokens.buttonRadius))
            .opacity(configuration.isPressed ? 0.7 : 1.0)
    }
}

/// Filled toolbar button for the Record affordance.
///
/// macOS toolbars suppress `.tint()` on `.borderedProminent` buttons, rendering
/// them grey instead of the requested color. This custom style draws the fill
/// explicitly so the color is guaranteed regardless of toolbar hosting context.
///
/// Usage: `.buttonStyle(ToolbarRecordButtonStyle(fill: .accentFill))` for idle,
/// `.buttonStyle(ToolbarRecordButtonStyle(fill: .signalRed))` for active.
public struct ToolbarRecordButtonStyle: ButtonStyle {
    let fill: Color
    @Environment(\.isEnabled) private var isEnabled

    public init(fill: Color) {
        self.fill = fill
    }

    public func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 14, weight: .medium))
            .foregroundStyle(.white)
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .frame(minHeight: 32)
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .fill(fill)
            )
            .opacity(
                !isEnabled ? 0.4 : configuration.isPressed ? 0.7 : 1.0
            )
    }
}

#Preview("JoinRecordButtonStyle") {
    VStack(spacing: 12) {
        Button {} label: {
            HStack(spacing: 6) {
                Image(systemName: "record.circle")
                Text("Join & Record")
            }
        }
        .buttonStyle(JoinRecordButtonStyle())

        Button("Record") {}
            .buttonStyle(JoinRecordButtonStyle())
            .disabled(true)
    }
    .padding()
    .background(Tokens.contentBackground)
}
