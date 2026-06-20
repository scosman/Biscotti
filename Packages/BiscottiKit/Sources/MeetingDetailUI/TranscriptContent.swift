import DataStore
import DesignSystem
import Foundation
import SwiftUI

/// Pure builders for transcript rendering: one `AttributedString` for the
/// selectable block view, and one plain-text string for the pasteboard.
///
/// Both are deterministic, side-effect-free functions over `[SegmentData]`
/// — easy to unit-test without any view or view model.
public enum TranscriptContent {
    // MARK: - Attributed string (for display)

    /// Builds a single `AttributedString` for the entire transcript.
    ///
    /// Per turn:
    /// - Speaker label: semibold, palette-derived color, clickable link
    ///   when the segment has a non-nil `speakerID`.
    /// - Two spaces + timestamp (MM:SS or H:MM:SS): mono, `.inkTertiary`,
    ///   optionally a clickable seek link when `canSeek` is true.
    /// - Newline + utterance text: system ~14pt, `.inkSecondary`.
    /// - Blank line between turns.
    ///
    /// - Parameters:
    ///   - segments: The transcript segments to render.
    ///   - canSeek: Whether timestamps should be clickable seek links.
    ///   - names: A map of diarization speaker ID to display name. When
    ///     a segment's `speakerID` is in this map, the assigned name is
    ///     shown instead of `speakerLabel`. Color is always keyed on
    ///     `speakerID` so it stays stable across renames.
    public static func attributedString(
        _ segments: [SegmentData], canSeek: Bool,
        names: [Int: String] = [:]
    ) -> AttributedString {
        var result = AttributedString()

        for (index, segment) in segments.enumerated() {
            // Speaker display name: assigned name or original label
            let displayName: String = if let sid = segment.speakerID,
                                         let assignedName = names[sid]
            {
                assignedName
            } else {
                segment.speakerLabel
            }

            // Speaker label
            var speaker = AttributedString(displayName)
            speaker.font = .system(size: 14, weight: .semibold)
            speaker.foregroundColor = speakerColor(for: segment)

            // Make speaker span clickable when the segment has a speaker ID
            if let sid = segment.speakerID {
                speaker.link = SpeakerLink.url(speakerID: sid)
            }

            result.append(speaker)

            // Two spaces + timestamp (+ play glyph when seekable)
            let timeText = TimeFormatting.formatPlaybackTime(segment.startTime)
            let timestampLabel = canSeek
                ? "  \(timeText) \u{25B6}\u{FE0E}"
                : "  \(timeText)"
            var timestamp = AttributedString(timestampLabel)
            timestamp.font = Font.biscottiMono(12)
            timestamp.foregroundColor = Color.inkTertiary
            if canSeek {
                timestamp.link = SeekLink.url(seconds: segment.startTime)
            }
            result.append(timestamp)

            // Newline + utterance (trim leading whitespace from text)
            let trimmedText = segment.text.drop(while: \.isWhitespace)
            var utterance = AttributedString("\n\(trimmedText)")
            utterance.font = .system(size: 14)
            utterance.foregroundColor = Color.inkSecondary
            result.append(utterance)

            // Paragraph break between turns
            if index < segments.count - 1 {
                result.append(AttributedString("\n\n"))
            }
        }

        return result
    }

    // MARK: - Plain text (for pasteboard)

    /// Builds a plain-text rendering of the transcript for clipboard copy.
    ///
    /// Format per turn:
    /// ```
    /// <Speaker>  MM:SS
    /// <utterance text>
    /// ```
    /// Blank line between turns.
    ///
    /// - Parameters:
    ///   - segments: The transcript segments to render.
    ///   - names: Optional speaker-ID-to-name map; same semantics as
    ///     `attributedString`.
    public static func plainText(
        _ segments: [SegmentData],
        names: [Int: String] = [:]
    ) -> String {
        segments.map { segment in
            let displayName: String = if let sid = segment.speakerID,
                                         let assignedName = names[sid]
            {
                assignedName
            } else {
                segment.speakerLabel
            }
            let timeText = TimeFormatting.formatPlaybackTime(segment.startTime)
            let trimmedText = segment.text.drop(while: \.isWhitespace)
            return "\(displayName)  \(timeText)\n\(trimmedText)"
        }
        .joined(separator: "\n\n")
    }

    // MARK: - Speaker color

    /// Stable per-speaker color from the shared avatar palette.
    ///
    /// When the segment has a non-nil `speakerID`, the color is keyed on
    /// a canonical string `"speaker-<id>"` so the color stays the same
    /// regardless of whether a name is assigned. Falls back to
    /// `speakerLabel` for segments without diarization data.
    public static func speakerColor(for segment: SegmentData) -> Color {
        let colorKey: String = if let sid = segment.speakerID {
            "speaker-\(sid)"
        } else {
            segment.speakerLabel
        }
        return Tokens.avatarPalette[
            avatarColorIndex(
                forKey: colorKey,
                paletteCount: Tokens.avatarPalette.count
            )
        ]
    }

    /// Legacy overload: stable per-speaker color from a label string.
    /// Kept for backward compatibility; new code should prefer the
    /// `SegmentData` overload.
    public static func speakerColor(for label: String) -> Color {
        Tokens.avatarPalette[
            avatarColorIndex(
                forKey: label,
                paletteCount: Tokens.avatarPalette.count
            )
        ]
    }
}
