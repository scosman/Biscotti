import SwiftUI

// MARK: - Kicker modifier

/// Applies the kicker style: JetBrains Mono 10.5pt medium, uppercase, tracking +1.47.
/// Usage: `Text("UPCOMING").kicker()`
private struct KickerModifier: ViewModifier {
    func body(content: Content) -> some View {
        content
            .font(.monoKicker)
            .textCase(.uppercase)
            .tracking(1.47)
    }
}

public extension View {
    /// Style this text as an uppercase mono kicker label.
    func kicker() -> some View {
        modifier(KickerModifier())
    }
}
