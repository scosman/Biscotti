import DataStore
import DesignSystem
import Foundation
import SwiftUI

/// Pure builders for transcript display and clipboard export.
///
/// Deterministic, side-effect-free functions over `[SegmentData]`
/// — easy to unit-test without any view or view model.
public enum TranscriptContent {
    // MARK: - Display name

    /// The display name for a segment's speaker: the assigned person name
    /// when the segment's `speakerID` is mapped in `names`, otherwise the
    /// original diarization `speakerLabel`.
    ///
    /// Shared by the transcript row (`TranscriptListView`) and `plainText`
    /// so on-screen and copied text resolve names identically.
    ///
    /// - Parameters:
    ///   - segment: The segment whose speaker name to resolve.
    ///   - names: A map of diarization speaker ID to assigned display name.
    public static func displayName(
        for segment: SegmentData, names: [Int: String]
    ) -> String {
        if let sid = segment.speakerID, let assignedName = names[sid] {
            return assignedName
        }
        return segment.speakerLabel
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
    ///     `displayName(for:names:)`.
    public static func plainText(
        _ segments: [SegmentData],
        names: [Int: String] = [:]
    ) -> String {
        segments.map { segment in
            let name = displayName(for: segment, names: names)
            let timeText = TimeFormatting.formatPlaybackTime(segment.startTime)
            let trimmedText = segment.text.drop(while: \.isWhitespace)
            return "\(name)  \(timeText)\n\(trimmedText)"
        }
        .joined(separator: "\n\n")
    }

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
