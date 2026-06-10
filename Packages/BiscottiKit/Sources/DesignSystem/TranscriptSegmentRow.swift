import SwiftUI

/// A row displaying a transcript segment: a speaker chip on the leading edge and the segment text.
public struct TranscriptSegmentRow: View {
    private let speakerLabel: String
    private let text: String

    public init(speakerLabel: String, text: String) {
        self.speakerLabel = speakerLabel
        self.text = text
    }

    public var body: some View {
        HStack(alignment: .top, spacing: Tokens.spacingSM) {
            Text(speakerLabel)
                .font(Tokens.speakerLabelFont)
                .padding(.horizontal, Tokens.spacingSM)
                .padding(.vertical, Tokens.spacingXS)
                .background(Tokens.speakerChipBackground, in: RoundedRectangle(cornerRadius: 4))
                .layoutPriority(1)

            Text(text)
                .font(Tokens.transcriptFont)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.vertical, Tokens.spacingXS)
    }
}

#Preview("Transcript Segment Row") {
    VStack(alignment: .leading, spacing: 0) {
        TranscriptSegmentRow(
            speakerLabel: "Speaker 0",
            text: "Hey, thanks for joining today."
        )
        TranscriptSegmentRow(
            speakerLabel: "Speaker 1",
            text: "No problem, happy to be here."
        )
        TranscriptSegmentRow(
            speakerLabel: "Speaker 0",
            text: "So the first thing on the agenda is the quarterly review. Let's go through the numbers."
        )
    }
    .padding()
    .frame(width: 400)
}
