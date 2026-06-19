import AppKit
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

    /// Focused find-match highlight: sage @ 35%.
    static let findHighlightFocused = sage.opacity(0.35)

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

    /// **The single canonical warning color for the entire app** (#C6891E,
    /// RGB 198/137/30).
    ///
    /// A warm ochre chosen to complement sage and read clearly on ivory
    /// backgrounds. Use this token everywhere you would reach for
    /// yellow/amber/orange for **warning semantics** -- do **not**
    /// introduce other yellows/oranges or use raw `.yellow` / `.orange`
    /// / `Color(.systemYellow)` / `Color(.systemOrange)` for warnings.
    ///
    /// **Approved usages:**
    /// - **Warning icons:** the primary use case. Warning triangles
    ///   (`exclamationmark.triangle.fill`), caution indicators, and
    ///   permission-denied state icons.
    /// - **Warning text:** dark enough to be legible as text on light
    ///   backgrounds if needed, but avoid relying on color alone to
    ///   convey warnings in text -- pair with an icon or contextual
    ///   label.
    /// - **Warning-tinted backgrounds:** use
    ///   `warningOchre.opacity(0.15)` for banner/chip fills.
    /// - **Button fills (if ever needed):** follow the same rule as
    ///   `signalRed` -- use a custom fill `ButtonStyle` with a
    ///   white/legible label, not `.tint()`, which macOS ignores for
    ///   custom colors on bordered/prominent buttons.
    static let warningOchre = Color(red: 0.776, green: 0.537, blue: 0.118)

    /// Window wall: flat warm-grey fallback (#E4E1D8).
    static let wall = Color(red: 0.894, green: 0.882, blue: 0.847)

    /// Sidebar tint: translucent ivory overlay (rgba 250,249,244 @ 82%).
    static let sidebarTint = Color(red: 0.980, green: 0.976, blue: 0.957).opacity(0.82)

    // MARK: - Recording redesign tokens

    /// Sidebar RECORDING NOW row fill; auto-stop card wash: signalRed @ 8%.
    static let recordingTintSoft = signalRed.opacity(0.08)

    /// Selected sidebar recording row fill: signalRed @ 12%.
    static let recordingTintStrong = signalRed.opacity(0.12)

    /// Light Stop/REC button hairline: signalRed @ 32%.
    static let recordingOutline = signalRed.opacity(0.32)

    /// Selected recording row inset stroke: signalRed @ 20%.
    static let recordingOutlineStrong = signalRed.opacity(0.20)

    /// Light Stop/REC button hover: signalRed @ 5%.
    static let recordingHoverFill = signalRed.opacity(0.05)

    /// Left chip amber kicker + value text color.
    static let warningChipText = warningOchre

    /// "Add note" + "Keep Recording" button fill: sage @ 12%.
    static let softSageFill = sage.opacity(0.12)
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

    static var warningOchre: Color {
        .warningOchre
    }
    // Note: `.hairline` and `.neutralChip` are less commonly used as ShapeStyles
    // so they are accessed through Color.hairline / Color.neutralChip directly.
}

// MARK: - NSColor mirrors (same RGB literals, for AppKit consumers)

/// AppKit-native mirrors of the F Sage palette, built from the same
/// RGB/alpha literals as the SwiftUI `Color` extensions above. Preferred
/// over `NSColor(Color.x)` to avoid color-space surprises.
///
/// These names intentionally shadow no built-in `NSColor` properties
/// (AppKit has no `.ink`, `.sage`, etc.). The naming mirrors the
/// `Color` extensions above for single-sourced consistency.
public extension NSColor {
    /// Primary text -- warm near-black (#1A1813).
    static let ink = NSColor(srgbRed: 0.102, green: 0.094, blue: 0.075, alpha: 1)

    /// Secondary text: ink @ 54%.
    static let inkSecondary = NSColor(srgbRed: 0.102, green: 0.094, blue: 0.075, alpha: 0.54)

    /// Tertiary text / chevrons: ink @ 34%.
    static let inkTertiary = NSColor(srgbRed: 0.102, green: 0.094, blue: 0.075, alpha: 0.34)

    /// Brand accent -- sage green (#4E7D5C).
    static let sage = NSColor(srgbRed: 0.306, green: 0.490, blue: 0.361, alpha: 1)

    /// Selection background: sage @ 14%.
    static let accentWashStrong = NSColor(srgbRed: 0.306, green: 0.490, blue: 0.361, alpha: 0.14)

    /// Focused find-match highlight: sage @ 35%.
    static let findHighlightFocused = NSColor(srgbRed: 0.306, green: 0.490, blue: 0.361, alpha: 0.35)

    /// Card border: warm dark @ 10%.
    static let cardStroke = NSColor(srgbRed: 0.102, green: 0.086, blue: 0.055, alpha: 0.10)
}
