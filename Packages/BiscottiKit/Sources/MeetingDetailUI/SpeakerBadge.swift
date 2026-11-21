import DesignSystem
import SwiftUI

/// Identifies a speaker by number as well as color, so the
/// transcript and the Assign Speaker Names sheet can be matched without
/// telling colors apart (and colors can repeat: the palette is hashed).
/// The number is the same one the sheet shows as "Speaker N".
struct SpeakerBadge: View {
    let speakerID: Int
    let color: Color
    var size: CGFloat = 18

    var body: some View {
        Text("\(speakerID)")
            .font(.system(size: size * 0.6, weight: .bold, design: .rounded))
            .monospacedDigit()
            .foregroundStyle(.ink)
            .frame(minWidth: size, minHeight: size)
            .padding(.horizontal, speakerID >= 10 ? 3 : 0)
            .background(Capsule().fill(color.opacity(0.35)))
            .overlay(Capsule().strokeBorder(color, lineWidth: 1.5))
            .accessibilityLabel("Speaker \(speakerID)")
    }
}
