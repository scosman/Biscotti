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
    /// - Speaker label: semibold, palette-derived color.
    /// - Two spaces + timestamp (MM:SS or H:MM:SS): mono, `.inkTertiary`,
    ///   optionally a clickable seek link when `canSeek` is true.
    /// - Newline + utterance text: system ~14pt, `.inkSecondary`.
    /// - Blank line between turns.
    public static func attributedString(
        _ segments: [SegmentData], canSeek: Bool
    ) -> AttributedString {
        var result = AttributedString()

        for (index, segment) in segments.enumerated() {
            // Speaker label
            var speaker = AttributedString(segment.speakerLabel)
            speaker.font = .system(size: 14, weight: .semibold)
            speaker.foregroundColor = speakerColor(for: segment.speakerLabel)
            result.append(speaker)

            // Two spaces + timestamp
            let timeText = TimeFormatting.formatPlaybackTime(segment.startTime)
            var timestamp = AttributedString("  \(timeText)")
            timestamp.font = Font.biscottiMono(12)
            timestamp.foregroundColor = Color.inkTertiary
            if canSeek {
                timestamp.link = SeekLink.url(seconds: segment.startTime)
            }
            result.append(timestamp)

            // Newline + utterance
            var utterance = AttributedString("\n\(segment.text)")
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
    public static func plainText(_ segments: [SegmentData]) -> String {
        segments.map { segment in
            let timeText = TimeFormatting.formatPlaybackTime(segment.startTime)
            return "\(segment.speakerLabel)  \(timeText)\n\(segment.text)"
        }
        .joined(separator: "\n\n")
    }

    // MARK: - Speaker color

    /// Stable per-speaker color from the shared avatar palette.
    /// Same label always maps to the same color.
    public static func speakerColor(for label: String) -> Color {
        Tokens.avatarPalette[
            avatarColorIndex(
                forKey: label,
                paletteCount: Tokens.avatarPalette.count
            )
        ]
    }
}
