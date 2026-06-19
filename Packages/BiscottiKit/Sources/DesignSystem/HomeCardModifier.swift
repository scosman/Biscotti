import SwiftUI

/// Applies the Home card style: white fill, 12pt corner radius, hairline stroke,
/// and a whisper shadow.
public struct HomeCardModifier: ViewModifier {
    public func body(content: Content) -> some View {
        content
            .background(Tokens.cardFill)
            .clipShape(RoundedRectangle(cornerRadius: Tokens.cardRadius))
            .overlay(
                RoundedRectangle(cornerRadius: Tokens.cardRadius)
                    .strokeBorder(Tokens.cardStroke, lineWidth: 0.5)
            )
            .shadow(color: .black.opacity(0.05), radius: 1.5, y: 1)
    }
}

public extension View {
    /// Wraps the view in a Home-style card (white fill, hairline border, whisper shadow).
    func homeCard() -> some View {
        modifier(HomeCardModifier())
    }
}

/// A thin hairline divider inset from the leading edge to align under text, not avatars.
public struct InsetDivider: View {
    private let leadingInset: CGFloat

    public init(leadingInset: CGFloat = 14) {
        self.leadingInset = leadingInset
    }

    public var body: some View {
        Tokens.hairline
            .frame(height: 0.5)
            .padding(.leading, leadingInset)
    }
}

#Preview("Home Card") {
    VStack(spacing: 8) {
        Text("Row 1")
            .padding(12)

        InsetDivider()

        Text("Row 2")
            .padding(12)
    }
    .homeCard()
    .padding(32)
    .background(Tokens.contentBackground)
}
