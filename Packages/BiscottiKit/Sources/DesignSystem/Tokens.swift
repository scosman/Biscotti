import SwiftUI

/// Shared design tokens: colors, typography, and spacing for the F Sage identity.
public enum Tokens {
    // MARK: - Colors

    /// Active-recording indicators (pulsing dot, toolbar "Recording..." pill, Stop button).
    /// Aliases `Color.signalRed` -- the single unified red for the app.
    public static let recordingRed = Color.signalRed

    /// Secondary text color (warm ink @ 54%).
    public static let secondaryText = Color.inkSecondary

    /// Background for banners (warning). Derived from the canonical `warningOchre`.
    public static let warningBackground = Color.warningOchre.opacity(0.15)

    /// Background for banners (error).
    public static let errorBackground = Color.signalRed.opacity(0.15)

    /// Speaker chip background (sage wash).
    public static let speakerChipBackground = Color.accentWashSoft

    // MARK: - Surfaces (warm ivory)

    /// Warm ivory content background.
    public static let contentBackground = Color.paper

    /// Card fill (adaptive: white / warm dark).
    public static let cardFill = Color.cardFill

    /// Hairline separator: ink @ 11%.
    public static let hairline = Color.hairline

    /// Card border stroke: warm ink @ 10%, 0.5pt.
    public static let cardStroke = Color.cardStroke

    /// Neutral chip fill: ink @ 6%.
    public static let neutralChip = Color.neutralChip

    /// Accent wash (soft, 8%) -- hero row background, speaker chips.
    public static let accentWashSoft = Color.accentWashSoft

    /// Accent wash (strong, 14%) -- selection background.
    public static let accentWashStrong = Color.accentWashStrong

    // MARK: - Recording redesign tokens

    /// Sidebar RECORDING NOW row fill; auto-stop card wash.
    public static let recordingTintSoft = Color.recordingTintSoft

    /// Selected sidebar recording row fill.
    public static let recordingTintStrong = Color.recordingTintStrong

    /// Light Stop/REC button hairline.
    public static let recordingOutline = Color.recordingOutline

    /// Selected recording row inset stroke.
    public static let recordingOutlineStrong = Color.recordingOutlineStrong

    /// Light Stop/REC button hover.
    public static let recordingHoverFill = Color.recordingHoverFill

    /// Left chip amber fill (<=5 min / overtime). Reuses `warningBackground`
    /// (warningOchre @ 0.15) per ui_design.md guidance -- close enough to
    /// the spec's 0.16 to avoid a near-duplicate token.
    public static let warningChipFill = warningBackground

    /// Left chip amber kicker + value text color.
    public static let warningChipText = Color.warningChipText

    /// "Add note" + "Keep Recording" button fill.
    public static let softSageFill = Color.softSageFill

    /// Button fills -- deeper sage for white-label contrast in dark.
    public static let accentFill = Color.accentFill

    /// Elevated control fill (white buttons/fields in light, card surface in dark).
    public static let elevatedFill = Color.elevatedFill

    /// Long-form body text (transcripts) -- brighter in dark for reading.
    public static let read = Color.read

    /// Custom progress-bar fills.
    public static let accentTrack = Color.accentTrack

    /// Standalone red text labels -- lighter in dark for AA legibility.
    public static let signalRedText = Color.signalRedText

    /// Home card shadow (adaptive opacity).
    public static let cardShadow = Color.cardShadow

    /// Control shadow for light-alert buttons (adaptive opacity).
    public static let controlShadow = Color.controlShadow

    /// Avatar stacked-ring border (matches surface behind overlapping avatars).
    public static let avatarRing = Color.avatarRing

    /// Sage accent -- formerly "liveGreen". Meet chip icon, "Next in" dot, conference video icon.
    public static let liveGreen = Color.sage

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

    /// Recording elapsed counter: JetBrains Mono largeTitle, weight 500.
    public static let elapsedTimeFont = Font.monoElapsed

    /// Title font for meeting headers.
    public static let meetingTitleFont = Font.headline

    /// Caption font for metadata (date, duration).
    public static let metadataFont = Font.subheadline.weight(.regular)

    /// Body font for transcript text.
    public static let transcriptFont = Font.body

    /// Small font for speaker labels.
    public static let speakerLabelFont = Font.caption.weight(.semibold)

    /// Section header font -- use `.kicker()` modifier at call sites instead.
    public static let sectionHeaderFont = Font.monoKicker

    // MARK: - Home Typography

    /// Greeting title: Newsreader Display ~32, weight 500. Apply `greetingTracking` via `.tracking()`.
    public static let greetingFont = Font.serifGreeting

    /// Tracking for the greeting title (-0.32pt).
    public static let greetingTracking: CGFloat = -0.32

    /// Date line: JetBrains Mono 15pt regular.
    public static let dateLine = Font.monoDate

    /// "Starting soon" hero title: 16pt semibold (SF Pro, unchanged).
    public static let heroTitle = Font.system(size: 16, weight: .semibold)

    /// Row title: 14.5pt medium (SF Pro, unchanged).
    public static let rowTitle = Font.system(size: 14.5, weight: .medium)

    /// Meta text: 12.5pt regular (SF Pro, unchanged).
    public static let metaText = Font.system(size: 12.5)

    /// Meta text medium weight: 12.5pt medium (SF Pro, unchanged).
    public static let metaTextMedium = Font.system(size: 12.5, weight: .medium)

    /// Group label: JetBrains Mono 10.5pt medium (rendered uppercase). Apply `groupLabelTracking`.
    public static let groupLabel = Font.monoKicker

    /// Tracking for group labels (+1.47pt, approx +0.14em at 10.5).
    public static let groupLabelTracking: CGFloat = 1.47

    /// Chip / Meet label: 11pt medium (SF Pro, unchanged).
    public static let chipLabel = Font.system(size: 11, weight: .medium)

    /// Stat chip text: JetBrains Mono 12.5pt medium.
    public static let statChipText = Font.monoStat

    /// Join button label: 13.5pt semibold (SF Pro, unchanged).
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

    /// Maximum width for readable content columns (meeting detail,
    /// event preview, pinned transport bar).
    public static let readableContentMaxWidth: CGFloat = 760

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

    /// Fixed width for the avatar column in home rows.
    public static let avatarColumnWidth: CGFloat = 80

    /// Default avatar size for ordinary rows.
    public static let avatarSize: CGFloat = 26

    /// Avatar size for the hero row.
    public static let heroAvatarSize: CGFloat = 28
}
