import SwiftUI

/// Shared design tokens: colors, typography, and spacing for a tight, Apple-native UI.
public enum Tokens {
    // MARK: - Colors

    /// Primary accent color (system red for recording state).
    public static let recordingRed = Color.red

    /// Secondary text color.
    public static let secondaryText = Color.secondary

    /// Background for banners (warning).
    public static let warningBackground = Color.yellow.opacity(0.15)

    /// Background for banners (error).
    public static let errorBackground = Color.red.opacity(0.15)

    /// Speaker chip background (subtle tint).
    public static let speakerChipBackground = Color.accentColor.opacity(0.12)

    // MARK: - Typography

    /// Large monospaced font for elapsed time display.
    public static let elapsedTimeFont = Font.system(.largeTitle, design: .monospaced).weight(.medium)

    /// Title font for meeting headers.
    public static let meetingTitleFont = Font.headline

    /// Caption font for metadata (date, duration).
    public static let metadataFont = Font.subheadline.weight(.regular)

    /// Body font for transcript text.
    public static let transcriptFont = Font.body

    /// Small font for speaker labels.
    public static let speakerLabelFont = Font.caption.weight(.semibold)

    /// Section header font (e.g. "PAST").
    public static let sectionHeaderFont = Font.caption.weight(.medium)

    // MARK: - Spacing (8-pt grid)

    /// Smallest spacing unit (4 pt).
    public static let spacingXS: CGFloat = 4

    /// Small spacing (8 pt).
    public static let spacingSM: CGFloat = 8

    /// Medium spacing (16 pt).
    public static let spacingMD: CGFloat = 16

    /// Large spacing (24 pt).
    public static let spacingLG: CGFloat = 24

    /// Extra-large spacing (32 pt).
    public static let spacingXL: CGFloat = 32
}
