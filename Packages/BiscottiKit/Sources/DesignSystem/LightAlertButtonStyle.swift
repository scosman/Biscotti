import SwiftUI

/// Light alert button style shared by Stop & Save and the recording-state
/// header button.
///
/// White `cardFill`, `recordingOutline` 0.5pt border, whisper shadow,
/// `signalRed` content, `recordingHoverFill` on hover. The caller's label
/// controls layout (padding, height); this style only provides the chrome.
public struct LightAlertButtonStyle: ButtonStyle {
    @State private var isHovering = false

    public init() {}

    public func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundStyle(Color.signalRed)
            .background(
                RoundedRectangle(cornerRadius: 9)
                    .fill(isHovering ? Color.recordingHoverFill : Tokens.cardFill)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 9)
                    .strokeBorder(Color.recordingOutline, lineWidth: 0.5)
            )
            // Tighter whisper shadow than HomeCardModifier (0.05/1.5/1)
            // -- intentional for the smaller button footprint.
            .shadow(color: .black.opacity(0.06), radius: 1, x: 0, y: 0.5)
            .opacity(configuration.isPressed ? 0.7 : 1.0)
            .onHover { isHovering = $0 }
    }
}

#Preview("LightAlertButtonStyle") {
    VStack(spacing: 16) {
        Button {} label: {
            HStack(spacing: 6) {
                Image(systemName: "stop.fill")
                    .font(.system(size: 9))
                Text("Stop & Save")
                    .font(.system(size: 13, weight: .medium))
            }
            .padding(.horizontal, 15)
            .frame(height: 34)
        }
        .buttonStyle(LightAlertButtonStyle())

        Button {} label: {
            HStack(spacing: 6) {
                Circle()
                    .fill(Color.signalRed)
                    .frame(width: 8, height: 8)
                Text("REC 02:14")
                    .font(.monoMetaMedium)
            }
            .padding(.horizontal, 16)
            .frame(height: 34)
        }
        .buttonStyle(LightAlertButtonStyle())
    }
    .padding()
    .background(Tokens.contentBackground)
}
