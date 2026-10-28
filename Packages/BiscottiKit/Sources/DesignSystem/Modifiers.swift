import AppKit
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

// MARK: - Pointing-hand cursor

public extension View {
    /// Shows the pointing-hand cursor while hovering, for text that acts
    /// as a link.
    func pointingHandCursor() -> some View {
        onHover { inside in
            if inside {
                NSCursor.pointingHand.push()
            } else {
                NSCursor.pop()
            }
        }
    }
}
