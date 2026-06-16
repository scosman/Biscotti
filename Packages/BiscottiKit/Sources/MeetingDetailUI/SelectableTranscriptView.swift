import DesignSystem
import SwiftUI

/// Displays a transcript as a single selectable `Text` block with
/// seek-link interception. Drag-select spans across speaker turns;
/// tapping a timestamp fires `onSeek` with the parsed time offset.
struct SelectableTranscriptView: View {
    private let attributed: AttributedString
    private let onSeek: (TimeInterval) -> Void

    init(
        attributed: AttributedString,
        onSeek: @escaping (TimeInterval) -> Void
    ) {
        self.attributed = attributed
        self.onSeek = onSeek
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
