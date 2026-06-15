import SwiftUI

// MARK: - Semantic color palette (F Sage)

public extension Color {
    /// Warm ivory content background (#FBFAF5).
    static let paper = Color(red: 0.984, green: 0.980, blue: 0.961)

    /// Primary text -- warm near-black (#1A1813).
    static let ink = Color(red: 0.102, green: 0.094, blue: 0.075)

    /// Brand accent -- sage green (#4E7D5C).
    static let sage = Color(red: 0.306, green: 0.490, blue: 0.361)

    /// Secondary text: ink @ 54%.
    static let inkSecondary = ink.opacity(0.54)

    /// Tertiary text / chevrons: ink @ 34%.
    static let inkTertiary = ink.opacity(0.34)

    /// Separator: ink @ 11%.
    static let hairline = ink.opacity(0.11)

    /// Neutral chip fill: ink @ 6%.
    static let neutralChip = ink.opacity(0.06)

    /// Card border (0.5pt): warm dark @ 10%.
    static let cardStroke = Color(red: 0.102, green: 0.086, blue: 0.055).opacity(0.10)

    /// Selection background: sage @ 14%.
    static let accentWashStrong = sage.opacity(0.14)

    /// Hero tint / speaker chip: sage @ 8%.
    static let accentWashSoft = sage.opacity(0.08)

    /// **The single canonical red for the entire app** (#B23320, RGB 178/51/32).
    ///
    /// A warm, dark-enough-for-text red chosen to complement sage. Use this
    /// token everywhere you would reach for red -- do **not** introduce other
    /// reds or use raw `Color.red` / `.systemRed`.
    ///
    /// **Approved usages:**
    /// - **Error / failure states:** error icons, error text, error-tinted
    ///   backgrounds (`signalRed.opacity(0.15)`). Dark enough for readable
    ///   error text on light backgrounds.
    /// - **Recording indicators:** the pulsing recording dot, "Recording..."
    ///   live-state labels and toolbar pills, and the Stop button fill.
    /// - **Destructive actions & buttons:** destructive text links and icons
    ///   via `.foregroundStyle(.signalRed)`. For a filled red destructive
    ///   button, use an explicit custom `ButtonStyle` that fills with
    ///   `signalRed` and sets a white label (same pattern as
    ///   `ToolbarRecordButtonStyle`). **Do not use `.tint(.signalRed)`** --
    ///   macOS ignores `.tint()` with custom colors on bordered/prominent
    ///   buttons, rendering them grey. System-rendered `.alert` /
    ///   `.confirmationDialog` destructive buttons are OS-styled; leave
    ///   them as-is.
    /// - **Button fills:** when used as a button background (recording or
    ///   destructive), pair with **white** text/icons for contrast.
    static let signalRed = Color(red: 0.698, green: 0.200, blue: 0.125)

    /// Window wall: flat warm-grey fallback (#E4E1D8).
    static let wall = Color(red: 0.894, green: 0.882, blue: 0.847)

    /// Sidebar tint: translucent ivory overlay (rgba 250,249,244 @ 82%).
    static let sidebarTint = Color(red: 0.980, green: 0.976, blue: 0.957).opacity(0.82)
}

// MARK: - ShapeStyle sugar

// Lets call sites use `.foregroundStyle(.ink)`, `.fill(.sage)`, `.background(.paper)`.

public extension ShapeStyle where Self == Color {
    static var paper: Color {
        .paper
    }

    static var ink: Color {
        .ink
    }

    static var sage: Color {
        .sage
    }

    static var inkSecondary: Color {
        .inkSecondary
    }

    static var inkTertiary: Color {
        .inkTertiary
    }

    static var signalRed: Color {
        .signalRed
    }
    // Note: `.hairline` and `.neutralChip` are less commonly used as ShapeStyles
    // so they are accessed through Color.hairline / Color.neutralChip directly.
}
