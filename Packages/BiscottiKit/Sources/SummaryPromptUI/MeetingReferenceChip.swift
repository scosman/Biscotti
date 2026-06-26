import DesignSystem
import SwiftUI

/// A read-only chip showing a meeting's title, date, and optional duration.
///
/// Used in the per-meeting prompt sheet header to identify which meeting
/// will be re-summarized.
struct MeetingReferenceChip: View {
    let reference: MeetingReference

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "waveform")
                .font(.system(size: 11))
                .foregroundStyle(.inkSecondary)

            Text(reference.title)
                .font(Tokens.metadataFont)
                .foregroundStyle(.inkSecondary)
                .lineLimit(1)

            Text(Self.dateFormatter.string(from: reference.date))
                .font(Tokens.metadataFont)
                .foregroundStyle(.inkSecondary)

            if let duration = reference.duration, duration > 0 {
                Text(Self.formatDuration(duration))
                    .font(Tokens.metadataFont)
                    .foregroundStyle(.inkSecondary)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(
            RoundedRectangle(cornerRadius: Tokens.chipRadius)
                .fill(Color.neutralChip)
        )
    }

    // MARK: - Formatting

    private static let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter
    }()

    private static func formatDuration(_ interval: TimeInterval) -> String {
        let totalMinutes = Int(interval / 60)
        if totalMinutes < 60 {
            return "\(totalMinutes)m"
        }
        let hours = totalMinutes / 60
        let minutes = totalMinutes % 60
        if minutes == 0 {
            return "\(hours)h"
        }
        return "\(hours)h \(minutes)m"
    }
}
