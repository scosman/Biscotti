import AppKit
import SwiftUI

// MARK: - Semantic color palette (F Sage) — appearance-adaptive

// Every token is defined once via `dynamicNSColor` / `dynamicColor`. Light values
// are the exact sRGB literals from the original static palette. Dark values come
// from the approved design (functional_spec.md §3). Views never branch on
// `colorScheme` — appearance is resolved entirely here.

// MARK: - NSColor tokens (single source of truth)

// Tokens that have AppKit consumers (markdown editor, etc.) are defined as
// `NSColor` first; the `Color` extension derives from them via `Color(nsColor:)`.
// Tokens used only in SwiftUI are defined directly via `dynamicColor`.

public extension NSColor {
    /// Primary text — warm near-black (#1A1813) / warm off-white (#F7F2E8).
    static let ink = dynamicNSColor(
        light: NSColor(srgbRed: 0.102, green: 0.094, blue: 0.075, alpha: 1),
        dark: NSColor(srgbRed: 0.969, green: 0.949, blue: 0.910, alpha: 1)
    )

    /// Secondary text: ink @ 54% / #F7F2E8 @ 58%.
    static let inkSecondary = dynamicNSColor(
        light: NSColor(srgbRed: 0.102, green: 0.094, blue: 0.075, alpha: 0.54),
        dark: NSColor(srgbRed: 0.969, green: 0.949, blue: 0.910, alpha: 0.58)
    )

    /// Tertiary text / chevrons: ink @ 34% / #F7F2E8 @ 36%.
    static let inkTertiary = dynamicNSColor(
        light: NSColor(srgbRed: 0.102, green: 0.094, blue: 0.075, alpha: 0.34),
        dark: NSColor(srgbRed: 0.969, green: 0.949, blue: 0.910, alpha: 0.36)
    )

    /// Brand accent — sage green (#4E7D5C / #86C295).
    static let sage = dynamicNSColor(
        light: NSColor(srgbRed: 0.306, green: 0.490, blue: 0.361, alpha: 1),
        dark: NSColor(srgbRed: 0.525, green: 0.761, blue: 0.584, alpha: 1)
    )

    /// Selection background: sage @ 14% / #86C295 @ 16%.
    static let accentWashStrong = dynamicNSColor(
        light: NSColor(srgbRed: 0.306, green: 0.490, blue: 0.361, alpha: 0.14),
        dark: NSColor(srgbRed: 0.525, green: 0.761, blue: 0.584, alpha: 0.16)
    )

    /// Focused find-match highlight: sage @ 35% / #86C295 @ 35%.
    static let findHighlightFocused = dynamicNSColor(
        light: NSColor(srgbRed: 0.306, green: 0.490, blue: 0.361, alpha: 0.35),
        dark: NSColor(srgbRed: 0.525, green: 0.761, blue: 0.584, alpha: 0.35)
    )

    /// Card border (0.5pt): warm dark @ 10% / #F7F2E8 @ 12%.
    static let cardStroke = dynamicNSColor(
        light: NSColor(srgbRed: 0.102, green: 0.086, blue: 0.055, alpha: 0.10),
        dark: NSColor(srgbRed: 0.969, green: 0.949, blue: 0.910, alpha: 0.12)
    )
}

// MARK: - Color tokens (SwiftUI)

public extension Color {
    /// Warm ivory content background (#FBFAF5 / #100E09).
    static let paper = dynamicColor(
        light: NSColor(srgbRed: 0.984, green: 0.980, blue: 0.961, alpha: 1),
        dark: NSColor(srgbRed: 0.063, green: 0.055, blue: 0.035, alpha: 1)
    )

    /// Primary text — warm near-black / warm off-white.
    static let ink = Color(nsColor: .ink)

    /// Brand accent — sage green.
    static let sage = Color(nsColor: .sage)

    /// Secondary text: ink @ 54% / warm off-white @ 58%.
    static let inkSecondary = Color(nsColor: .inkSecondary)

    /// Tertiary text / chevrons: ink @ 34% / warm off-white @ 36%.
    static let inkTertiary = Color(nsColor: .inkTertiary)

    /// Separator: ink @ 11% / #F7F2E8 @ 12%.
    static let hairline = dynamicColor(
        light: NSColor(srgbRed: 0.102, green: 0.094, blue: 0.075, alpha: 0.11),
        dark: NSColor(srgbRed: 0.969, green: 0.949, blue: 0.910, alpha: 0.12)
    )

    /// Neutral chip fill: ink @ 6% / #F7F2E8 @ 7%.
    static let neutralChip = dynamicColor(
        light: NSColor(srgbRed: 0.102, green: 0.094, blue: 0.075, alpha: 0.06),
        dark: NSColor(srgbRed: 0.969, green: 0.949, blue: 0.910, alpha: 0.07)
    )

    /// Card border (0.5pt).
    static let cardStroke = Color(nsColor: .cardStroke)

    /// Selection background: sage @ 14% / #86C295 @ 16%.
    static let accentWashStrong = Color(nsColor: .accentWashStrong)

    /// Focused find-match highlight: sage @ 35% / #86C295 @ 35%.
    static let findHighlightFocused = Color(nsColor: .findHighlightFocused)

    /// Hero tint / speaker chip: sage @ 8% / #86C295 @ 12%.
    static let accentWashSoft = dynamicColor(
        light: NSColor(srgbRed: 0.306, green: 0.490, blue: 0.361, alpha: 0.08),
        dark: NSColor(srgbRed: 0.525, green: 0.761, blue: 0.584, alpha: 0.12)
    )

    /// **The single canonical red for the entire app** (#B23320 / #E5604A).
    ///
    /// A warm red chosen to complement sage. In dark mode, brightens to maintain
    /// contrast. Use this token for **marks**: dots, icons, stop-square, fills,
    /// borders. For standalone red **text** labels on dark, use `signalRedText`
    /// instead (lighter for AA legibility).
    ///
    /// Do **not** introduce other reds or use raw `Color.red` / `.systemRed`.
    ///
    /// **Approved usages:**
    /// - **Error / failure states:** error icons, error-tinted backgrounds
    ///   (`signalRed.opacity(0.15)`).
    /// - **Recording indicators:** the pulsing recording dot, Stop button fill.
    /// - **Destructive actions & buttons:** destructive icons and filled
    ///   destructive buttons (pair with white label).
    static let signalRed = dynamicColor(
        light: NSColor(srgbRed: 0.698, green: 0.200, blue: 0.125, alpha: 1),
        dark: NSColor(srgbRed: 0.898, green: 0.376, blue: 0.290, alpha: 1)
    )

    /// **The single canonical warning color** (#C6891E / #E8A13A).
    ///
    /// A warm ochre for warning **icons** (triangles) and the pulsing warning
    /// **dot**. In dark mode, brightens to maintain contrast. For amber **text**
    /// labels, use `warningChipText` (lighter in dark for legibility).
    ///
    /// Do **not** introduce other yellows/oranges for warnings.
    static let warningOchre = dynamicColor(
        light: NSColor(srgbRed: 0.776, green: 0.537, blue: 0.118, alpha: 1),
        dark: NSColor(srgbRed: 0.910, green: 0.631, blue: 0.227, alpha: 1)
    )

    /// Window wall: flat warm-grey fallback (#E4E1D8 / #110F09).
    static let wall = dynamicColor(
        light: NSColor(srgbRed: 0.894, green: 0.882, blue: 0.847, alpha: 1),
        dark: NSColor(srgbRed: 0.067, green: 0.059, blue: 0.035, alpha: 1)
    )

    /// Sidebar tint: translucent ivory / dark overlay.
    static let sidebarTint = dynamicColor(
        light: NSColor(srgbRed: 0.980, green: 0.976, blue: 0.957, alpha: 0.82),
        dark: NSColor(srgbRed: 0.078, green: 0.071, blue: 0.051, alpha: 0.74)
    )

    // MARK: - Recording redesign tokens

    /// Sidebar RECORDING NOW row fill; auto-stop card wash: signalRed @ 8%.
    /// Auto-adapts via the dynamic `signalRed` base.
    static let recordingTintSoft = signalRed.opacity(0.08)

    /// Selected sidebar recording row fill: signalRed @ 12%.
    static let recordingTintStrong = signalRed.opacity(0.12)

    /// Light Stop/REC button hairline: signalRed @ 32% / #E5604A @ 36%.
    static let recordingOutline = dynamicColor(
        light: NSColor(srgbRed: 0.698, green: 0.200, blue: 0.125, alpha: 0.32),
        dark: NSColor(srgbRed: 0.898, green: 0.376, blue: 0.290, alpha: 0.36)
    )

    /// Selected recording row inset stroke: signalRed @ 20%.
    static let recordingOutlineStrong = signalRed.opacity(0.20)

    /// Light Stop/REC button hover: signalRed @ 5%.
    static let recordingHoverFill = signalRed.opacity(0.05)

    /// Left chip amber kicker + value text (#C6891E / #F0C04A).
    /// Separate from `warningOchre` in dark (brighter for text legibility).
    static let warningChipText = dynamicColor(
        light: NSColor(srgbRed: 0.776, green: 0.537, blue: 0.118, alpha: 1),
        dark: NSColor(srgbRed: 0.941, green: 0.753, blue: 0.290, alpha: 1)
    )

    /// "Add note" + "Keep Recording" button fill: sage @ 12% / #86C295 @ 14%.
    static let softSageFill = dynamicColor(
        light: NSColor(srgbRed: 0.306, green: 0.490, blue: 0.361, alpha: 0.12),
        dark: NSColor(srgbRed: 0.525, green: 0.761, blue: 0.584, alpha: 0.14)
    )

    // MARK: - New semantic tokens (Phase 1)

    /// Card fill (#FFFFFF / #1A170F). All card surfaces adapt via this token.
    static let cardFill = dynamicColor(
        light: NSColor(srgbRed: 1.0, green: 1.0, blue: 1.0, alpha: 1),
        dark: NSColor(srgbRed: 0.102, green: 0.090, blue: 0.059, alpha: 1)
    )

    /// Button fills — deeper sage for white-label contrast (#4E7D5C / #56906A).
    /// Light value equals `sage`; dark is a touch deeper so white labels pass AA.
    static let accentFill = dynamicColor(
        light: NSColor(srgbRed: 0.306, green: 0.490, blue: 0.361, alpha: 1),
        dark: NSColor(srgbRed: 0.337, green: 0.565, blue: 0.416, alpha: 1)
    )

    /// Long-form body text (transcripts): ink @ 54% / #F7F2E8 @ 75%.
    /// Brighter than `inkSecondary` in dark for comfortable sustained reading.
    static let read = dynamicColor(
        light: NSColor(srgbRed: 0.102, green: 0.094, blue: 0.075, alpha: 0.54),
        dark: NSColor(srgbRed: 0.969, green: 0.949, blue: 0.910, alpha: 0.75)
    )

    /// Elevated control fill — white buttons/fields (#FFFFFF / #1A170F).
    /// Light = white; dark = card surface (Stop&Save, REC pill, focused title).
    static let elevatedFill = dynamicColor(
        light: NSColor(srgbRed: 1.0, green: 1.0, blue: 1.0, alpha: 1),
        dark: NSColor(srgbRed: 0.102, green: 0.090, blue: 0.059, alpha: 1)
    )

    /// Custom progress-bar fills (#4E7D5C / #5E9A6F).
    /// Light = sage; dark = a touch less bright than text sage.
    static let accentTrack = dynamicColor(
        light: NSColor(srgbRed: 0.306, green: 0.490, blue: 0.361, alpha: 1),
        dark: NSColor(srgbRed: 0.369, green: 0.604, blue: 0.435, alpha: 1)
    )

    /// Standalone red text labels (#B23320 / #F08A78).
    /// Lighter than `signalRed` in dark for AA legibility on dark backgrounds.
    /// Use for "RECORDING" labels, error messages, "Remove association" text.
    static let signalRedText = dynamicColor(
        light: NSColor(srgbRed: 0.698, green: 0.200, blue: 0.125, alpha: 1),
        dark: NSColor(srgbRed: 0.941, green: 0.541, blue: 0.471, alpha: 1)
    )

    /// Home card shadow: black @ 5% / black @ 40%.
    static let cardShadow = dynamicColor(
        light: NSColor(srgbRed: 0, green: 0, blue: 0, alpha: 0.05),
        dark: NSColor(srgbRed: 0, green: 0, blue: 0, alpha: 0.40)
    )

    /// Control shadow (light-alert buttons): black @ 6% / black @ 40%.
    static let controlShadow = dynamicColor(
        light: NSColor(srgbRed: 0, green: 0, blue: 0, alpha: 0.06),
        dark: NSColor(srgbRed: 0, green: 0, blue: 0, alpha: 0.40)
    )
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

    /// New tokens (Phase 1)
    static var accentFill: Color {
        .accentFill
    }

    static var read: Color {
        .read
    }

    static var elevatedFill: Color {
        .elevatedFill
    }

    static var accentTrack: Color {
        .accentTrack
    }

    static var signalRedText: Color {
        .signalRedText
    }

    static var cardShadow: Color {
        .cardShadow
    }

    static var controlShadow: Color {
        .controlShadow
    }

    static var cardFill: Color {
        .cardFill
    }
}
