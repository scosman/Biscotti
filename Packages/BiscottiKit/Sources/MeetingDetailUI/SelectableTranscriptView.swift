import DesignSystem
import SwiftUI

/// Displays a transcript as a single selectable `Text` block with
/// seek-link and speaker-link interception. Drag-select spans across
/// speaker turns; tapping a timestamp fires `onSeek` with the parsed
/// time offset; tapping a speaker name fires `onSpeaker` with the
/// speaker ID to open the mapping sheet.
///
/// **Equatable guard:** the parent view (`MeetingDetailView`) re-evaluates
/// its body on every playback tick (~4 Hz) because it reads
/// `playbackCurrentTime` for the transport bar. That re-evaluation creates
/// a new `SelectableTranscriptView` with new closures (closures are never
/// equal), which without the `Equatable` conformance would force SwiftUI
/// to re-evaluate this body every tick. For a long transcript,
/// re-evaluating `Text(attributed).textSelection(.enabled)` triggers a
/// full AppKit `NSTextView` re-layout that pegs the CPU. Equality keys on
/// every input that affects rendered content (`transcriptID` + `canSeek`
/// + `speakerNames`); the `attributed` string and closures are excluded
/// because the VM's cache already rebuilds the string when these inputs
/// change.
struct SelectableTranscriptView: View, Equatable {
    /// Stable identity for the displayed transcript version.
    let transcriptID: UUID

    /// Whether seek-link styling is active. Mirrors `canPlay` from the
    /// VM -- the attributed string is built differently when seek links
    /// are tappable vs. plain text, so a flip must trigger re-render.
    let canSeek: Bool

    /// Speaker name assignments; included in equality so a name change
    /// triggers re-render. The actual names are baked into `attributed`
    /// by the VM's cache -- this field is here solely for the equality
    /// check.
    let speakerNames: [Int: String]

    /// Speaker color-key overrides; included in equality so a color-key
    /// change (e.g. merging two speakers to one person) triggers re-render.
    let speakerColorKeys: [Int: String]

    private let attributed: AttributedString
    private let onSeek: (TimeInterval) -> Void
    private let onSpeaker: (Int) -> Void

    init(
        transcriptID: UUID,
        canSeek: Bool,
        speakerNames: [Int: String] = [:],
        speakerColorKeys: [Int: String] = [:],
        attributed: AttributedString,
        onSeek: @escaping (TimeInterval) -> Void,
        onSpeaker: @escaping (Int) -> Void = { _ in }
    ) {
        self.transcriptID = transcriptID
        self.canSeek = canSeek
        self.speakerNames = speakerNames
        self.speakerColorKeys = speakerColorKeys
        self.attributed = attributed
        self.onSeek = onSeek
        self.onSpeaker = onSpeaker
    }

    nonisolated static func == (
        lhs: SelectableTranscriptView,
        rhs: SelectableTranscriptView
    ) -> Bool {
        lhs.transcriptID == rhs.transcriptID
            && lhs.canSeek == rhs.canSeek
            && lhs.speakerNames == rhs.speakerNames
            && lhs.speakerColorKeys == rhs.speakerColorKeys
    }

    var body: some View {
        Text(attributed)
            .textSelection(.enabled)
            .tint(.inkTertiary)
            .environment(\.openURL, OpenURLAction { url in
                // Speaker links take priority
                if let speakerID = SpeakerLink.speakerID(from: url) {
                    onSpeaker(speakerID)
                    return .handled
                }
                if let seconds = SeekLink.seconds(from: url) {
                    onSeek(seconds)
                    return .handled
                }
                return .systemAction
            })
    }
}
