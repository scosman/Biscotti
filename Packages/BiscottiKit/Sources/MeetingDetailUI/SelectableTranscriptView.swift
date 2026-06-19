import DesignSystem
import SwiftUI

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
/// full AppKit `NSTextView` re-layout that pegs the CPU. Equality keys on
/// every input that affects rendered content (`transcriptID` + `canSeek`);
/// the `attributed` string and `onSeek` closure are excluded because the
/// VM's cache already rebuilds the string when these inputs change.
///
/// By conforming to `Equatable` on the content-determining inputs
/// (`transcriptID` + `canSeek`) and excluding the closure, then applying
/// `.equatable()` at the call site, SwiftUI skips body re-evaluation
/// when the transcript hasn't changed -- which is every tick during
/// normal playback.
struct SelectableTranscriptView: View, Equatable {
    /// Stable identity for the displayed transcript version.
    let transcriptID: UUID

    /// Whether seek-link styling is active. Mirrors `canPlay` from the
    /// VM -- the attributed string is built differently when seek links
    /// are tappable vs. plain text, so a flip must trigger re-render.
    let canSeek: Bool

    private let attributed: AttributedString
    private let onSeek: (TimeInterval) -> Void

    init(
        transcriptID: UUID,
        canSeek: Bool,
        attributed: AttributedString,
        onSeek: @escaping (TimeInterval) -> Void
    ) {
        self.transcriptID = transcriptID
        self.canSeek = canSeek
        self.attributed = attributed
        self.onSeek = onSeek
    }

    nonisolated static func == (lhs: SelectableTranscriptView, rhs: SelectableTranscriptView) -> Bool {
        lhs.transcriptID == rhs.transcriptID && lhs.canSeek == rhs.canSeek
    }

    var body: some View {
        Text(attributed)
            .textSelection(.enabled)
            .tint(.inkTertiary)
            .environment(\.openURL, OpenURLAction { url in
                if let seconds = SeekLink.seconds(from: url) {
                    onSeek(seconds)
                    return .handled
                }
                return .systemAction
            })
    }
}
