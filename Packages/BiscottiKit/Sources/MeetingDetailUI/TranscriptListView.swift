import DataStore
import DesignSystem
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
/// spike on long transcripts.
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
/// view itself is intentionally *not* `Equatable`: `header` is a fresh
/// closure capturing whatever local `@State`/`@Observable` values changed
/// on every re-render, and there is no way to compare closures for
/// equality. Only the recycled segment rows (`TranscriptRowsView` below)
/// opt into the row-recycling equality guard, since only their inputs
/// are meaningfully comparable. Previously this type applied `Equatable`
/// (and callers wrapped it in `.equatable()`) to the *whole* view
/// including `header`, which caused SwiftUI to skip re-rendering the
/// header -- and everything in it, including the Copy button's
/// "Copied" checkmark -- whenever only chrome-relevant state changed
/// (see `TranscriptRowsView` below for where that guard now lives).
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
            // Non-recycled header row (page chrome). Deliberately NOT
            // behind the `TranscriptRowsView.equatable()` guard below --
            // see the type doc comment above.
            header
                .readableRowWidth()
                .listRowSeparator(.hidden)
                .listRowBackground(Color.clear)
                .listRowInsets(EdgeInsets())

            // Recycled transcript segment rows. Guarded by `.equatable()`
            // so a parent re-render that only touches header-relevant
            // state (e.g. the Copy button's `didCopy` flag, or the ~4 Hz
            // playback tick) doesn't re-diff every row.
            TranscriptRowsView(
                transcriptID: transcriptID,
                canSeek: canSeek,
                segments: segments,
                speakerNames: speakerNames,
                speakerColorKeys: speakerColorKeys,
                onSeek: onSeek,
                onSpeaker: onSpeaker
            )
            .equatable()
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
    }
}

/// The recycled transcript segment rows, split out from
/// `TranscriptListView` so the row-recycling `Equatable` guard can be
/// scoped to just the rows -- never to `header`, which must always
/// re-render fresh (see `TranscriptListView`'s doc comment).
///
/// Equality keys on `transcriptID` + `canSeek` + `speakerNames` +
/// `speakerColorKeys` so SwiftUI skips re-diffing rows when the
/// transcript hasn't changed (e.g. on the ~4 Hz playback tick the parent
/// re-renders on), but re-renders when a speaker is renamed or merged
/// (the segments and closures are excluded from the comparison --
/// segments are keyed to the version via `transcriptID`, and closures
/// are never equal).
struct TranscriptRowsView: View, Equatable {
    let transcriptID: UUID
    let canSeek: Bool
    let segments: [SegmentData]
    var speakerNames: [Int: String] = [:]
    var speakerColorKeys: [Int: String] = [:]
    let onSeek: (TimeInterval) -> Void
    var onSpeaker: (Int) -> Void = { _ in }

    nonisolated static func == (lhs: TranscriptRowsView, rhs: TranscriptRowsView) -> Bool {
        lhs.transcriptID == rhs.transcriptID
            && lhs.canSeek == rhs.canSeek
            && lhs.speakerNames == rhs.speakerNames
            && lhs.speakerColorKeys == rhs.speakerColorKeys
    }

    var body: some View {
        ForEach(segments) { segment in
            TranscriptSegmentRow(
                segment: segment,
                speakerName: TranscriptContent.displayName(
                    for: segment, names: speakerNames
                ),
                speakerColor: TranscriptContent.speakerColor(
                    for: segment, colorKeys: speakerColorKeys
                ),
                canSeek: canSeek,
                onSeek: onSeek,
                onSpeaker: onSpeaker
            )
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
}

/// A single transcript segment row: speaker chip, label, timestamp,
/// and utterance text.
private struct TranscriptSegmentRow: View {
    let segment: SegmentData
    /// The resolved speaker display name (assigned person or label).
    let speakerName: String
    let speakerColor: Color
    let canSeek: Bool
    let onSeek: (TimeInterval) -> Void
    /// Tapped with the segment's speaker ID to open the mapping sheet.
    let onSpeaker: (Int) -> Void

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
