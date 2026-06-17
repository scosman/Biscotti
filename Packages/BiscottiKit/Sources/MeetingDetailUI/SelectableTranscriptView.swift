import DesignSystem
import os
import SwiftUI

// MARK: - SEEKLOOP diagnostic logger (temporary -- remove after diagnosis)

private let transcriptViewLogger = Logger(
    subsystem: "net.scosman.biscotti",
    category: "SEEKLOOP"
)

/// Displays a transcript as a single selectable `Text` block with
/// seek-link interception. Drag-select spans across speaker turns;
/// tapping a timestamp fires `onSeek` with the parsed time offset.
///
/// **Equatable guard:** the parent view (`MeetingDetailView`) re-evaluates
/// its body on every playback tick (~4 Hz) because it reads
/// `playbackCurrentTime` for the transport bar. That re-evaluation creates
/// a new `SelectableTranscriptView` with a new `onSeek` closure (closures
/// are never equal), which without the `Equatable` conformance would force
/// SwiftUI to re-evaluate this body every tick. For a long transcript,
/// re-evaluating `Text(attributed).textSelection(.enabled)` triggers a
/// full AppKit `NSTextView` re-layout that pegs the CPU.
///
/// By conforming to `Equatable` on `transcriptID` alone (the closure is
/// excluded) and applying `.equatable()` at the call site, SwiftUI skips
/// body re-evaluation when the transcript hasn't changed -- which is every
/// tick during normal playback.
struct SelectableTranscriptView: View, Equatable {
    /// Stable identity for the displayed transcript. Used by the
    /// `Equatable` conformance to let SwiftUI skip body re-evaluation
    /// when only the parent's unrelated state (e.g. `playbackCurrentTime`)
    /// changed.
    let transcriptID: UUID

    private let attributed: AttributedString
    private let onSeek: (TimeInterval) -> Void

    init(
        transcriptID: UUID,
        attributed: AttributedString,
        onSeek: @escaping (TimeInterval) -> Void
    ) {
        self.transcriptID = transcriptID
        self.attributed = attributed
        self.onSeek = onSeek
    }

    nonisolated static func == (lhs: SelectableTranscriptView, rhs: SelectableTranscriptView) -> Bool {
        lhs.transcriptID == rhs.transcriptID
    }

    var body: some View {
        _ = Self._printChanges() // SEEKLOOP diagnostic -- remove after diagnosis
        Text(attributed)
            .textSelection(.enabled)
            .tint(.inkTertiary)
            .environment(\.openURL, OpenURLAction { url in
                if let seconds = SeekLink.seconds(from: url) {
                    transcriptViewLogger.warning(
                        "SEEKLOOP OpenURLAction fired seconds=\(seconds, format: .fixed(precision: 6))"
                    )
                    onSeek(seconds)
                    return .handled
                }
                return .systemAction
            })
    }
}
