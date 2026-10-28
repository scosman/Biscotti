import DataStore
import DesignSystem
import Foundation
import SwiftUI

/// Pure builders for transcript speaker colors.
///
/// Deterministic, side-effect-free functions over `SegmentData`
/// — easy to unit-test without any view or view model. Name resolution
/// and plain-text rendering live in `Formatting.TranscriptTextFormatting`.
public enum TranscriptContent {
    // MARK: - Color keys

    /// The color key of a segment's speaker.
    ///
    /// Priority:
    /// 1. `colorKeys[speakerID]` when present (typically `"person-<UUID>"`
    ///    so merged speakers share a color).
    /// 2. `"speaker-<id>"`.
    /// 3. `speakerLabel` for segments without diarization data.
    public static func colorKey(
        for segment: SegmentData,
        colorKeys: [Int: String] = [:]
    ) -> String {
        if let speakerID = segment.speakerID {
            return colorKeys[speakerID] ?? "speaker-\(speakerID)"
        }
        return segment.speakerLabel
    }

    /// The color for a run label's color key. The reserved keys
    /// ``RunLabel/youColorKey`` and ``RunLabel/othersColorKey`` map to
    /// `sage` and `inkSecondary`; every other key picks from the avatar palette.
    public static func color(forKey key: String) -> Color {
        switch key {
        case RunLabel.youColorKey:
            .sage
        case RunLabel.othersColorKey:
            .inkSecondary
        default:
            Tokens.avatarPalette[
                avatarColorIndex(
                    forKey: key,
                    paletteCount: Tokens.avatarPalette.count
                )
            ]
        }
    }

    // MARK: - Speaker color

    /// Stable per-speaker color from the shared avatar palette, keyed by
    /// ``colorKey(for:colorKeys:)``.
    public static func speakerColor(
        for segment: SegmentData,
        colorKeys: [Int: String] = [:]
    ) -> Color {
        speakerColor(for: colorKey(for: segment, colorKeys: colorKeys))
    }

    /// Stable per-speaker color for a given speaker ID, respecting
    /// color-key overrides. Used by the speaker mapping sheet to render
    /// color dots consistent with the transcript.
    ///
    /// - Parameters:
    ///   - speakerID: The diarization speaker ID.
    ///   - colorKeys: Per-speaker-ID override keys (same map used by the
    ///     transcript row). When the speaker has an override, the
    ///     color is keyed on that value; otherwise `"speaker-<id>"`.
    public static func speakerColor(
        forSpeakerID speakerID: Int,
        colorKeys: [Int: String] = [:]
    ) -> Color {
        speakerColor(for: colorKeys[speakerID] ?? "speaker-\(speakerID)")
    }

    /// Stable per-speaker color from a key string.
    public static func speakerColor(for label: String) -> Color {
        Tokens.avatarPalette[
            avatarColorIndex(
                forKey: label,
                paletteCount: Tokens.avatarPalette.count
            )
        ]
    }
}
