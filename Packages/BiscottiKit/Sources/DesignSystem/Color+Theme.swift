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
    // Note: `.hairline` and `.neutralChip` are less commonly used as ShapeStyles
    // so they are accessed through Color.hairline / Color.neutralChip directly.
}
