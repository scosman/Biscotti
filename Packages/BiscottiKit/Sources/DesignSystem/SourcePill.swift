import SwiftUI

/// Capsule-shaped pill showing a video icon and a conference platform name.
///
/// Shown only when a conference platform is known; omitted otherwise.
/// Used in the meeting detail meta line.
public struct SourcePill: View {
    private let platform: String

    public init(platform: String) {
        self.platform = platform
    }

    public var body: some View {
        Label {
            Text(platform)
                .foregroundStyle(.inkSecondary)
        } icon: {
            Image(systemName: "video.fill")
                .foregroundStyle(.sage)
        }
        .font(.system(size: 11, weight: .medium))
        .padding(.horizontal, 7)
        .frame(height: 19)
        .background(Tokens.neutralChip, in: Capsule())
    }
}

#Preview("SourcePill") {
    HStack(spacing: 8) {
        SourcePill(platform: "Google Meet")
        SourcePill(platform: "Zoom")
        SourcePill(platform: "Teams")
    }
    .padding()
    .background(Tokens.contentBackground)
}
