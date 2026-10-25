import SwiftUI

/// Capsule pill marking a meeting that was created from an uploaded audio
/// file rather than a live recording. Styled like ``SourcePill``.
public struct ImportedAudioPill: View {
    private let fileName: String?

    /// - Parameter fileName: The original file's name, shown as a tooltip.
    public init(fileName: String? = nil) {
        self.fileName = fileName
    }

    public var body: some View {
        Label {
            Text("Imported audio")
                .foregroundStyle(.inkSecondary)
        } icon: {
            Image(systemName: "square.and.arrow.down")
                .foregroundStyle(.sage)
        }
        .font(.system(size: 11, weight: .medium))
        .padding(.horizontal, 7)
        .frame(height: 19)
        .background(Tokens.neutralChip, in: Capsule())
        .help(fileName.map { "Imported from \($0)" } ?? "Imported from an audio file")
        .accessibilityLabel("Imported audio")
    }
}

#Preview("ImportedAudioPill") {
    ImportedAudioPill(fileName: "standup.m4a")
        .padding()
        .background(Tokens.contentBackground)
}
