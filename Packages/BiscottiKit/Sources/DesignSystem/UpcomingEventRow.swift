import SwiftUI

/// Compact row for upcoming meeting-like events in the sidebar, home, or menu bar.
///
/// Defaults to a single-line `HStack` (title left, time + badge right).
/// Pass `twoLine: true` for a stacked layout: title on line 1, time + badge
/// on line 2 (used by the sidebar upcoming section).
public struct UpcomingEventRow: View {
    private let title: String
    private let timeText: String
    private let platformBadge: String?
    private let twoLine: Bool

    public init(
        title: String,
        timeText: String,
        platformBadge: String? = nil,
        twoLine: Bool = false
    ) {
        self.title = title
        self.timeText = timeText
        self.platformBadge = platformBadge
        self.twoLine = twoLine
    }

    public var body: some View {
        if twoLine {
            twoLineLayout
        } else {
            oneLineLayout
        }
    }

    // MARK: - Layouts

    private var oneLineLayout: some View {
        HStack(spacing: Tokens.spacingSM) {
            Text(title)
                .font(.body)
                .lineLimit(1)

            Spacer()

            timeLabel

            badgeLabel
        }
        .contentShape(Rectangle())
    }

    private var twoLineLayout: some View {
        VStack(alignment: .leading, spacing: Tokens.spacingXS) {
            Text(title)
                .font(.body)
                .lineLimit(1)

            HStack(spacing: Tokens.spacingSM) {
                timeLabel

                Spacer()

                badgeLabel
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
    }

    // MARK: - Shared sub-views

    private var timeLabel: some View {
        Text(timeText)
            .font(Tokens.metadataFont)
            .foregroundStyle(Tokens.secondaryText)
            .monospacedDigit()
    }

    @ViewBuilder
    private var badgeLabel: some View {
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
}

#Preview("Upcoming Event Row — 1-line") {
    VStack(alignment: .leading, spacing: 8) {
        UpcomingEventRow(title: "Standup", timeText: "in 12m", platformBadge: "Zoom")
        UpcomingEventRow(title: "1:1 with Sam", timeText: "2:30 PM", platformBadge: "Meet")
        UpcomingEventRow(title: "Planning", timeText: "in 1h 30m")
    }
    .padding()
    .frame(width: 280)
}

#Preview("Upcoming Event Row — 2-line") {
    VStack(alignment: .leading, spacing: 8) {
        UpcomingEventRow(title: "Standup", timeText: "in 12m", platformBadge: "Zoom", twoLine: true)
        UpcomingEventRow(title: "1:1 with Sam", timeText: "2:30 PM", platformBadge: "Meet", twoLine: true)
        UpcomingEventRow(title: "Planning", timeText: "in 1h 30m", twoLine: true)
    }
    .padding()
    .frame(width: 280)
}
