import SwiftUI

/// A neutral pill chip showing an icon and text, used for at-a-glance stats.
///
/// Renders as: `[icon text]` in a rounded rectangle filled with neutral grey.
/// The icon can be tinted independently (e.g. accent for calendar, green for
/// "next in" dot).
public struct StatChip: View {
    private let icon: String
    private let tint: Color
    private let text: String

    public init(icon: String, tint: Color, text: String) {
        self.icon = icon
        self.tint = tint
        self.text = text
    }

    public var body: some View {
        HStack(spacing: 5) {
            Image(systemName: icon)
                .foregroundStyle(tint)
                .font(.system(size: 11))

            Text(text)
                .font(Tokens.statChipText)
                .foregroundStyle(.inkSecondary)
        }
        .padding(.vertical, 0)
        .padding(.horizontal, 10)
        .frame(height: 24)
        .background(
            RoundedRectangle(cornerRadius: Tokens.chipRadius)
                .fill(Tokens.neutralChip)
        )
    }
}

#Preview("StatChips") {
    HStack(spacing: Tokens.statChipSpacing) {
        StatChip(icon: "calendar", tint: .sage, text: "5 meetings left today")
        StatChip(icon: "clock", tint: .inkSecondary, text: "2h 10m scheduled")
        StatChip(icon: "circle.fill", tint: .sage, text: "Next in 6m")
    }
    .padding()
    .background(Tokens.contentBackground)
}
