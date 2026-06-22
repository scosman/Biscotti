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
/// **Equatable guard:** the parent re-evaluates its body on every
/// playback tick (~4 Hz) because it reads `playbackCurrentTime` for
/// the transport bar. Equality keys on `transcriptID` + `canSeek` so
/// SwiftUI skips body re-evaluation when the transcript hasn't changed.
struct TranscriptListView<Header: View>: View, Equatable {
    /// Stable identity for the displayed transcript version.
    let transcriptID: UUID

    /// Whether seek links are tappable. Mirrors `canPlay` from the VM.
    let canSeek: Bool

    /// The transcript segments to display.
    let segments: [SegmentData]

    /// Callback when the user taps a timestamp to seek playback.
    let onSeek: (TimeInterval) -> Void

    /// Non-recycled header view (page chrome) placed before the
    /// recycled transcript rows. Pass `EmptyView()` when no header
    /// is needed.
    let header: Header

    nonisolated static func == (lhs: TranscriptListView, rhs: TranscriptListView) -> Bool {
        lhs.transcriptID == rhs.transcriptID && lhs.canSeek == rhs.canSeek
    }

    var body: some View {
        List {
            // Non-recycled header row (page chrome).
            header
                .readableRowWidth()
                .listRowSeparator(.hidden)
                .listRowBackground(Color.clear)
                .listRowInsets(EdgeInsets())

            // Recycled transcript segment rows.
            ForEach(segments) { segment in
                TranscriptSegmentRow(
                    segment: segment,
                    speakerColor: TranscriptContent.speakerColor(
                        for: segment.speakerLabel
                    ),
                    canSeek: canSeek,
                    onSeek: onSeek
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
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
    }
}

/// A single transcript segment row: speaker chip, label, timestamp,
/// and utterance text.
private struct TranscriptSegmentRow: View {
    let segment: SegmentData
    let speakerColor: Color
    let canSeek: Bool
    let onSeek: (TimeInterval) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            headerLine
            utteranceText
        }
        .textSelection(.enabled)
    }

    private var headerLine: some View {
        HStack(alignment: .center, spacing: Tokens.spacingXS) {
            // Speaker color chip
            Circle()
                .fill(speakerColor)
                .frame(width: 8, height: 8)

            // Speaker label
            Text(segment.speakerLabel)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(speakerColor)

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
            .foregroundStyle(.inkSecondary)
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
