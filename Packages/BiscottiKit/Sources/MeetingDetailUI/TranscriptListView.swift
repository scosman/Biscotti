import DataStore
import DesignSystem
import Formatting
import SwiftUI

/// Displays a transcript as a recycling `List` of per-segment rows,
/// with an optional non-recycled header at the top.
///
/// Each segment row shows a speaker color chip, the speaker label,
/// a timestamp (optionally tappable to seek), and the utterance text.
/// Text within each row is individually selectable via
/// `.textSelection(.enabled)`.
///
/// **Single scroll container:** When used as the page-level layout for
/// the transcript tab, the `header` parameter carries the page chrome
/// (title, calendar card, tab bar) so it scrolls with the transcript
/// inside one `List` -- no nested scroll views. The header is a plain
/// non-recycled row; only the transcript segment rows are recycled.
///
/// **Full-width List, constrained row content:** The `List` spans the
/// full pane width so the scrollbar sits flush at the right window
/// edge. Inside each row, content is capped at the page's max
/// readable width and left-aligned, matching the ScrollView path.
///
/// **Performance:** Unlike the previous single-`Text(AttributedString)`
/// renderer, this view leverages SwiftUI's `List` row recycling so
/// only visible rows are materialized -- fixing the ~450MB memory
/// spike on long transcripts. `ForEach(segments)` stays a *direct*
/// child of `List`'s own content builder (not nested inside another
/// custom container) so `List` can identify and recycle each segment
/// as its own row; only the per-row content is individually wrapped in
/// `.equatable()` (see `TranscriptSegmentRow` below) -- never a
/// container that itself produces multiple rows.
///
/// Each row's speaker label shows the assigned person name (when the
/// segment's `speakerID` is mapped in `speakerNames`) in the speaker's
/// color, and is tappable to open the speaker-mapping sheet via
/// `onSpeaker`. Speakers assigned to the same person share a color via
/// `speakerColorKeys`.
///
/// **`header` is always fresh, never Equatable-gated.** `header` carries
/// page chrome owned by the parent (title, tags, calendar card, tab bar
/// -- including the Copy button's transient "Copied" feedback). This
/// view itself is intentionally *not* `Equatable`, and nothing wraps the
/// whole view (or the whole `ForEach`) in `.equatable()` -- only
/// individual `TranscriptSegmentRow`s opt in, each keyed on its own
/// (comparable) segment/speaker/canSeek inputs. `header` is a fresh
/// closure capturing whatever local `@State`/`@Observable` values
/// changed on every re-render (closures can't be compared for equality
/// at all), so it must never sit behind an equality guard. Previously
/// this type applied `Equatable` (and callers wrapped it in
/// `.equatable()`) to the *whole* view including `header`, which caused
/// SwiftUI to skip re-rendering the header -- and everything in it,
/// including the Copy button's "Copied" checkmark -- whenever only
/// chrome-relevant state changed.
struct TranscriptListView<Header: View>: View {
    /// Stable identity for the displayed transcript version.
    let transcriptID: UUID

    /// Whether seek links are tappable. Mirrors `canPlay` from the VM.
    let canSeek: Bool

    /// The transcript segments to display.
    let segments: [SegmentData]

    /// Speaker ID -> assigned display name. A segment whose `speakerID`
    /// is present shows the assigned name instead of `speakerLabel`.
    var speakerNames: [Int: String] = [:]

    /// Speaker ID -> color-key override (e.g. `"person-<UUID>"`) so
    /// speakers merged onto the same person share a color.
    var speakerColorKeys: [Int: String] = [:]

    /// Callback when the user taps a timestamp to seek playback.
    let onSeek: (TimeInterval) -> Void

    /// Callback when the user taps a speaker label, with the speaker ID,
    /// to open the speaker-mapping sheet.
    var onSpeaker: (Int) -> Void = { _ in }

    /// Non-recycled header view (page chrome) placed before the
    /// recycled transcript rows. Pass `EmptyView()` when no header
    /// is needed.
    let header: Header

    var body: some View {
        List {
            // Non-recycled header row (page chrome). Never behind an
            // `.equatable()` guard -- see the type doc comment above.
            header
                .readableRowWidth()
                .listRowSeparator(.hidden)
                .listRowBackground(Color.clear)
                .listRowInsets(EdgeInsets())

            // Recycled transcript segment rows: `ForEach` stays a direct
            // child of `List` so each segment is its own recyclable row.
            // Each row individually opts into `.equatable()` (keyed on
            // its own segment + resolved speaker name/color + canSeek)
            // so re-renders that don't change a given row's content skip
            // re-diffing it -- e.g. the ~4 Hz playback tick, or the Copy
            // button's `didCopy` flag flipping in `header` above.
            ForEach(segments) { segment in
                TranscriptSegmentRow(
                    segment: segment,
                    speakerName: TranscriptTextFormatting.displayName(
                        for: segment, names: speakerNames
                    ),
                    speakerColor: TranscriptContent.speakerColor(
                        for: segment, colorKeys: speakerColorKeys
                    ),
                    canSeek: canSeek,
                    onSeek: onSeek,
                    onSpeaker: onSpeaker
                )
                .equatable()
                .readableRowWidth()
                .listRowSeparator(.hidden)
                .listRowBackground(Color.clear)
                .listRowInsets(EdgeInsets(
                    top: Tokens.spacingXS,
                    leading: 0,
                    bottom: Tokens.spacingXS + 2,
                    trailing: 0
                ))
            }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
    }
}

/// A single transcript segment row: speaker chip, label, timestamp,
/// and utterance text.
///
/// Conforms to `Equatable` (compared on `segment`, `speakerName`,
/// `speakerColor`, and `canSeek` -- the only things this row actually
/// renders) so each row can be wrapped in `.equatable()` independently,
/// letting SwiftUI skip re-diffing a row whose content hasn't changed
/// without affecting sibling rows or `TranscriptListView`'s `header`.
struct TranscriptSegmentRow: View, Equatable {
    let segment: SegmentData
    /// The resolved speaker display name (assigned person or label).
    let speakerName: String
    let speakerColor: Color
    let canSeek: Bool
    let onSeek: (TimeInterval) -> Void
    /// Tapped with the segment's speaker ID to open the mapping sheet.
    let onSpeaker: (Int) -> Void

    nonisolated static func == (lhs: TranscriptSegmentRow, rhs: TranscriptSegmentRow) -> Bool {
        lhs.segment == rhs.segment
            && lhs.speakerName == rhs.speakerName
            && lhs.speakerColor == rhs.speakerColor
            && lhs.canSeek == rhs.canSeek
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            headerLine
            utteranceText
        }
        .textSelection(.enabled)
    }

    @ViewBuilder
    private var speakerLabel: some View {
        // Tappable to open the mapping sheet when the segment carries a
        // diarization speaker ID; plain colored text otherwise.
        if let speakerID = segment.speakerID {
            Button {
                onSpeaker(speakerID)
            } label: {
                Text(speakerName)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(speakerColor)
            }
            .buttonStyle(.plain)
            .cursor(.pointingHand)
        } else {
            Text(speakerName)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(speakerColor)
        }
    }

    private var headerLine: some View {
        HStack(alignment: .center, spacing: Tokens.spacingXS) {
            // Speaker color chip
            Circle()
                .fill(speakerColor)
                .frame(width: 8, height: 8)

            // Speaker label (tappable to open the mapping sheet)
            speakerLabel

            // Timestamp (with optional seek action)
            if canSeek {
                Button {
                    onSeek(segment.startTime)
                } label: {
                    Text(
                        "\(TimeFormatting.formatPlaybackTime(segment.startTime)) \u{25B6}\u{FE0E}"
                    )
                    .font(Font.biscottiMono(12))
                    .foregroundStyle(.inkTertiary)
                }
                .buttonStyle(.plain)
                .cursor(.pointingHand)
                .padding(.leading, Tokens.spacingXS)
            } else {
                Text(TimeFormatting.formatPlaybackTime(segment.startTime))
                    .font(Font.biscottiMono(12))
                    .foregroundStyle(.inkTertiary)
                    .padding(.leading, Tokens.spacingXS)
            }
        }
    }

    private var utteranceText: some View {
        Text(segment.text.drop(while: \.isWhitespace))
            .font(.system(size: 14))
            .foregroundStyle(.read)
            .fixedSize(horizontal: false, vertical: true)
    }
}

// MARK: - Row width constraint

private extension View {
    /// Constrains the view to the page's readable content width with
    /// standard horizontal padding, centered within the full row.
    /// Text stays left-aligned inside the capped block (inner frame
    /// uses `.leading`); the block itself is centered in the full
    /// pane width (outer frame uses default `.center`).
    func readableRowWidth() -> some View {
        padding(.horizontal, Tokens.homeHorizontalPadding)
            .frame(
                maxWidth: Tokens.readableContentMaxWidth,
                alignment: .leading
            )
            .frame(maxWidth: .infinity)
    }
}

// MARK: - Cursor modifier

private extension View {
    /// Sets the mouse cursor to a pointing hand on hover (macOS).
    func cursor(_ cursor: NSCursor) -> some View {
        onHover { inside in
            if inside {
                cursor.push()
            } else {
                NSCursor.pop()
            }
        }
    }
}
