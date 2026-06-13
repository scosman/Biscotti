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

    // MARK: - Home / Pro Palette

    /// Near-white content background (#FBFBFC) for the detail pane behind Home.
    public static let contentBackground = Color(red: 0.984, green: 0.984, blue: 0.988)

    /// Card fill (white).
    public static let cardFill = Color.white

    /// Hairline separator: black @ 8%.
    public static let hairline = Color.black.opacity(0.08)

    /// Card border stroke: black @ 7%, 0.5pt.
    public static let cardStroke = Color.black.opacity(0.07)

    /// Neutral chip fill: black @ 5%.
    public static let neutralChip = Color.black.opacity(0.05)

    /// Accent wash (soft, 6%) — hero row background.
    public static let accentWashSoft = Color.accentColor.opacity(0.06)

    /// Accent wash (strong, 14%) — selection background.
    public static let accentWashStrong = Color.accentColor.opacity(0.14)

    /// Success / "live" green (#1A9D5A) — Meet chip icon, "Next in" dot.
    public static let liveGreen = Color(red: 0.102, green: 0.616, blue: 0.353)

    /// Fixed 16-color avatar palette. Order is permanent; never reorder.
    public static let avatarPalette: [Color] = [
        Color(red: 0.369, green: 0.608, blue: 1.0), // blue
        Color(red: 1.0, green: 0.608, blue: 0.416), // orange
        Color(red: 0.482, green: 0.827, blue: 0.537), // green
        Color(red: 0.780, green: 0.608, blue: 1.0), // purple
        Color(red: 1.0, green: 0.820, blue: 0.400), // yellow
        Color(red: 0.416, green: 0.839, blue: 0.784), // teal
        Color(red: 1.0, green: 0.561, blue: 0.639), // pink
        Color(red: 0.553, green: 0.420, blue: 0.878), // indigo
        Color(red: 0.933, green: 0.380, blue: 0.184), // red-orange
        Color(red: 0.212, green: 0.659, blue: 0.353), // emerald
        Color(red: 0.365, green: 0.471, blue: 0.882), // cobalt
        Color(red: 0.867, green: 0.494, blue: 0.808), // magenta
        Color(red: 0.647, green: 0.580, blue: 0.467), // brown
        Color(red: 0.431, green: 0.706, blue: 0.835), // sky
        Color(red: 0.835, green: 0.631, blue: 0.333), // amber
        Color(red: 0.604, green: 0.459, blue: 0.525) // mauve
    ]

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

    // MARK: - Home Typography

    /// Greeting title: 32pt bold. Apply `greetingTracking` via `.tracking()`.
    public static let greetingFont = Font.system(size: 32, weight: .bold)

    /// Tracking for the greeting title (-0.6pt tighter).
    public static let greetingTracking: CGFloat = -0.6

    /// Date line: 15pt regular.
    public static let dateLine = Font.system(size: 15, weight: .regular)

    /// "Starting soon" hero title: 16pt semibold.
    public static let heroTitle = Font.system(size: 16, weight: .semibold)

    /// Row title: 14.5pt medium.
    public static let rowTitle = Font.system(size: 14.5, weight: .medium)

    /// Meta text: 12.5pt regular.
    public static let metaText = Font.system(size: 12.5)

    /// Meta text medium weight: 12.5pt medium.
    public static let metaTextMedium = Font.system(size: 12.5, weight: .medium)

    /// Group label: 11.5pt semibold (rendered uppercase). Apply `groupLabelTracking` via `.tracking()`.
    public static let groupLabel = Font.system(size: 11.5, weight: .semibold)

    /// Tracking for group labels (+0.5pt wider).
    public static let groupLabelTracking: CGFloat = 0.5

    /// Chip / Meet label: 11pt medium.
    public static let chipLabel = Font.system(size: 11, weight: .medium)

    /// Stat chip text: 12.5pt medium.
    public static let statChipText = Font.system(size: 12.5, weight: .medium)

    /// Join button label: 13.5pt semibold.
    public static let joinButtonLabel = Font.system(size: 13.5, weight: .semibold)

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

    // MARK: - Home Layout

    /// Maximum width for the Home content column.
    public static let homeColumnMaxWidth: CGFloat = 800

    /// Page padding top/bottom.
    public static let homeVerticalPadding: CGFloat = 24

    /// Page padding leading/trailing.
    public static let homeHorizontalPadding: CGFloat = 32

    /// Hero row internal padding.
    public static let heroPadding: CGFloat = 18

    /// Standard row vertical padding.
    public static let rowVerticalPadding: CGFloat = 11

    /// Standard row horizontal padding.
    public static let rowHorizontalPadding: CGFloat = 14

    /// Gap from group label to card.
    public static let groupToCardGap: CGFloat = 9

    /// Gap from card to next group label.
    public static let cardToGroupGap: CGFloat = 30

    /// Stat chip horizontal spacing.
    public static let statChipSpacing: CGFloat = 8

    // MARK: - Home Radii

    /// Card corner radius.
    public static let cardRadius: CGFloat = 12

    /// Button / search / chip radius.
    public static let buttonRadius: CGFloat = 8

    /// Stat chip radius.
    public static let chipRadius: CGFloat = 7

    /// Meet chip radius.
    public static let meetChipRadius: CGFloat = 6

    // MARK: - Avatar

    /// Fixed width for the avatar column in rows.
    public static let avatarColumnWidth: CGFloat = 78

    /// Default avatar size for ordinary rows.
    public static let avatarSize: CGFloat = 26

    /// Avatar size for the hero row.
    public static let heroAvatarSize: CGFloat = 28
}
