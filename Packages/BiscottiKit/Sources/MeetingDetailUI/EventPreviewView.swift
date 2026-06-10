import Calendar
import DesignSystem
import SwiftUI

/// Read-only preview of an upcoming calendar event with a Record action.
///
/// Shown when the user selects an upcoming event in the sidebar. Displays
/// event metadata and a prominent "Record" button that starts recording
/// pre-associated with this event (C4 explicit key).
public struct EventPreviewView: View {
    private let viewModel: EventPreviewViewModel

    public init(viewModel: EventPreviewViewModel) {
        self.viewModel = viewModel
    }

    public var body: some View {
        if let event = viewModel.event {
            eventContent(event)
        } else {
            VStack(spacing: Tokens.spacingSM) {
                Text("Event not found")
                    .font(Tokens.metadataFont)
                    .foregroundStyle(Tokens.secondaryText)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func eventContent(_ event: CalendarEvent) -> some View {
        VStack(alignment: .leading, spacing: Tokens.spacingMD) {
            // Header
            Text(event.title)
                .font(Tokens.meetingTitleFont)

            // Time
            HStack(spacing: Tokens.spacingSM) {
                Text(Self.formatDateRange(
                    start: event.start,
                    end: event.end
                ))
                .font(Tokens.metadataFont)
                .foregroundStyle(Tokens.secondaryText)
            }

            // Calendar + platform badge
            HStack(spacing: Tokens.spacingSM) {
                Circle()
                    .fill(Color(hex: event.calendarColorHex))
                    .frame(width: 8, height: 8)
                Text(event.calendarTitle)
                    .font(.caption)
                    .foregroundStyle(Tokens.secondaryText)

                if let platform = event.conferencePlatform {
                    Text(platform.capitalized)
                        .font(.caption)
                        .padding(.horizontal, 4)
                        .padding(.vertical, 2)
                        .background(
                            RoundedRectangle(cornerRadius: 3)
                                .fill(Color.secondary.opacity(0.12))
                        )
                }
            }

            if event.attendeeCount > 0 {
                Text("\(event.attendeeCount) attendee\(event.attendeeCount == 1 ? "" : "s")")
                    .font(Tokens.metadataFont)
                    .foregroundStyle(Tokens.secondaryText)
            }

            Divider()

            // Record action
            RecordButton(
                isDisabled: viewModel.recordDisabled
            ) {
                Task {
                    await viewModel.startRecording()
                }
            }

            Spacer()
        }
        .padding(Tokens.spacingLG)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    // MARK: - Formatting

    private static let dateRangeFormatter: DateIntervalFormatter = {
        let formatter = DateIntervalFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter
    }()

    static func formatDateRange(start: Date, end: Date) -> String {
        dateRangeFormatter.string(from: start, to: end)
    }
}
