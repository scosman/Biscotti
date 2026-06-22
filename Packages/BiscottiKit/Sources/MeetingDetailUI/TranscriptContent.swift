import DataStore
import DesignSystem
import Foundation
import SwiftUI

/// Pure builders for transcript display and clipboard export.
///
/// Deterministic, side-effect-free functions over `[SegmentData]`
/// — easy to unit-test without any view or view model.
public enum TranscriptContent {
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
            let trimmedText = segment.text.drop(while: \.isWhitespace)
            return "\(segment.speakerLabel)  \(timeText)\n\(trimmedText)"
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
