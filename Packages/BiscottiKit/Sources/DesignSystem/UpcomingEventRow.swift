import SwiftUI

/// Compact row for upcoming meeting-like events in the sidebar, home, or menu bar.
public struct UpcomingEventRow: View {
    private let title: String
    private let timeText: String
    private let platformBadge: String?

    public init(title: String, timeText: String, platformBadge: String? = nil) {
        self.title = title
        self.timeText = timeText
        self.platformBadge = platformBadge
    }

    public var body: some View {
        HStack(spacing: Tokens.spacingSM) {
            Text(title)
                .font(.body)
                .lineLimit(1)

            Spacer()

            Text(timeText)
                .font(Tokens.metadataFont)
                .foregroundStyle(Tokens.secondaryText)
                .monospacedDigit()

            if let platformBadge {
                Text(platformBadge)
                    .font(.caption2)
                    .foregroundStyle(Tokens.secondaryText)
                    .padding(.horizontal, 4)
                    .padding(.vertical, 2)
                    .background(
                        RoundedRectangle(cornerRadius: 3)
                            .fill(Color.secondary.opacity(0.12))
                    )
            }
        }
        .contentShape(Rectangle())
    }
}

#Preview("Upcoming Event Row") {
    VStack(alignment: .leading, spacing: 8) {
        UpcomingEventRow(title: "Standup", timeText: "in 12m", platformBadge: "Zoom")
        UpcomingEventRow(title: "1:1 with Sam", timeText: "2:30 PM", platformBadge: "Meet")
        UpcomingEventRow(title: "Planning", timeText: "in 1h 30m")
    }
    .padding()
    .frame(width: 280)
}
