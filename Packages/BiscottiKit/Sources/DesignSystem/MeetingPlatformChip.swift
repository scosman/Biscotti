import SwiftUI

/// Inline capsule showing a video icon and a platform label (e.g. "Google Meet").
///
/// Rendered only when a conference platform is known. Uses the "live" green for
/// the video icon to signal an active/available conference link.
public struct MeetingPlatformChip: View {
    private let platform: String

    public init(platform: String) {
        self.platform = platform
    }

    public var body: some View {
        HStack(spacing: 4) {
            Image(systemName: "video.fill")
                .foregroundStyle(Tokens.liveGreen)
                .font(.system(size: 9))

            Text(platform)
                .font(Tokens.chipLabel)
                .foregroundStyle(.inkSecondary)
        }
        .padding(.vertical, 0)
        .padding(.horizontal, 7)
        .frame(height: 19)
        .background(
            RoundedRectangle(cornerRadius: Tokens.meetChipRadius)
                .fill(Color.neutralChip)
        )
    }
}

#Preview("MeetingPlatformChip") {
    HStack(spacing: 8) {
        MeetingPlatformChip(platform: "Google Meet")
        MeetingPlatformChip(platform: "Zoom")
    }
    .padding()
    .background(Tokens.contentBackground)
}
