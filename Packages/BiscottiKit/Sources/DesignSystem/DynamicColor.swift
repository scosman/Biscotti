import AppKit
import SwiftUI

// MARK: - Appearance-resolving color helpers

/// Returns an `NSColor` that resolves to `light` under `.aqua` and `dark` under
/// `.darkAqua`. This is the **single point** in the codebase where appearance is
/// branched -- view code never checks `colorScheme`.
///
/// Both inputs must be sRGB. The provider closure captures only `Sendable` values
/// (`NSColor` + `[NSAppearance.Name]`), satisfying Swift 6 strict concurrency.
func dynamicNSColor(light: NSColor, dark: NSColor) -> NSColor {
    NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? dark : light
    }
}

/// SwiftUI sugar: a dynamic `Color` from light/dark sRGB `NSColor` literals.
func dynamicColor(light: NSColor, dark: NSColor) -> Color {
    Color(nsColor: dynamicNSColor(light: light, dark: dark))
}
