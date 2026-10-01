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
    // MARK: - Speaker color

    /// Stable per-speaker color from the shared avatar palette.
    ///
    /// Color key priority:
    /// 1. If `colorKeys[speakerID]` is present, use that key (typically
    ///    `"person-<UUID>"` so merged speakers share a color).
    /// 2. Otherwise fall back to `"speaker-<id>"`.
    /// 3. Segments without diarization data use `speakerLabel`.
    ///
    /// - Parameters:
    ///   - segment: The segment whose speaker color to determine.
    ///   - colorKeys: Per-speaker-ID override keys derived from person
    ///     assignments. Defaults to empty (no overrides).
    public static func speakerColor(
        for segment: SegmentData,
        colorKeys: [Int: String] = [:]
    ) -> Color {
        let colorKey: String = if let sid = segment.speakerID,
                                  let override = colorKeys[sid]
        {
            override
        } else if let sid = segment.speakerID {
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
        let colorKey = colorKeys[speakerID] ?? "speaker-\(speakerID)"
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
