import AppKit
import Calendar
import DesignSystem
import SwiftUI

/// Read-only preview of an upcoming calendar event with time-based
/// action buttons: Open Link, Join and Record, or plain Record.
///
/// Shown when the user selects an upcoming event in the sidebar.
/// Displays full event details: title, date range, calendar badge,
/// platform, location, organizer, attendees, notes, and meeting URL.
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
        ScrollView {
            VStack(alignment: .leading, spacing: Tokens.spacingMD) {
                // Title
                Text(event.title)
                    .font(Tokens.meetingTitleFont)

                // Date range
                HStack(spacing: Tokens.spacingSM) {
                    Text(Self.formatDateRange(
                        start: event.start,
                        end: event.end
                    ))
                    .font(Tokens.metadataFont)
                    .foregroundStyle(Tokens.secondaryText)
                }

                // Calendar + platform badge
                calendarBadge(event)

                Divider()

                // Action buttons
                actionButtons

                Divider()

                // Details sections
                detailSections(event)

                Spacer()
            }
            .padding(Tokens.spacingLG)
        }
        .frame(
            maxWidth: .infinity,
            maxHeight: .infinity,
            alignment: .topLeading
        )
    }

    // MARK: - Calendar badge

    private func calendarBadge(
        _ event: CalendarEvent
    ) -> some View {
        HStack(spacing: Tokens.spacingSM) {
            Circle()
                .fill(Color(hex: event.calendarColorHex))
                .frame(width: 8, height: 8)
            Text(event.calendarTitle)
                .font(.caption)
                .foregroundStyle(Tokens.secondaryText)

            if let platform = event.conferencePlatform {
                Text(platform)
                    .font(.caption)
                    .padding(.horizontal, 4)
                    .padding(.vertical, 2)
                    .background(
                        RoundedRectangle(cornerRadius: 3)
                            .fill(Color.secondary.opacity(0.12))
                    )
            }
        }
    }

    // MARK: - Action buttons

    private var actionButtons: some View {
        HStack(spacing: Tokens.spacingSM) {
            switch viewModel.primaryAction {
            case .openLink:
                Button {
                    viewModel.openLink()
                } label: {
                    Label("Open Link", systemImage: "link")
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)

            case .joinAndRecord:
                Button {
                    Task { await viewModel.joinAndRecord() }
                } label: {
                    Label(
                        "Join and Record",
                        systemImage: "video.fill"
                    )
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .disabled(viewModel.recordDisabled)

            case .record:
                RecordButton(
                    isDisabled: viewModel.recordDisabled
                ) {
                    Task { await viewModel.startRecording() }
                }
            }

            if viewModel.showSecondaryRecord {
                RecordButton(
                    isDisabled: viewModel.recordDisabled
                ) {
                    Task { await viewModel.startRecording() }
                }
            }
        }
    }

    // MARK: - Detail sections

    @ViewBuilder
    private func detailSections(
        _ event: CalendarEvent
    ) -> some View {
        // Conference URL
        if let url = event.conferenceURL {
            detailRow(
                label: "Meeting Link",
                value: url.absoluteString
            )
        }

        // Location
        if let location = event.location,
           !location.isEmpty
        {
            detailRow(label: "Location", value: location)
        }

        // Organizer
        if let organizer = event.organizer {
            detailRow(
                label: "Organizer",
                value: organizer.displayName
            )
        }

        // Attendees
        if !event.attendees.isEmpty {
            VStack(alignment: .leading, spacing: Tokens.spacingXS) {
                Text("Attendees (\(event.attendees.count))")
                    .font(Tokens.sectionHeaderFont)
                    .foregroundStyle(Tokens.secondaryText)

                let names = event.attendees.map(\.displayName)
                Text(names.joined(separator: ", "))
                    .font(.body)
                    .foregroundStyle(Tokens.secondaryText)
            }
        }

        // Notes
        if let notes = event.notes, !notes.isEmpty {
            VStack(alignment: .leading, spacing: Tokens.spacingXS) {
                Text("Notes")
                    .font(Tokens.sectionHeaderFont)
                    .foregroundStyle(Tokens.secondaryText)

                Text(notes)
                    .font(.body)
                    .foregroundStyle(Tokens.secondaryText)
                    .textSelection(.enabled)
            }
        }
    }

    private func detailRow(
        label: String,
        value: String
    ) -> some View {
        VStack(alignment: .leading, spacing: Tokens.spacingXS) {
            Text(label)
                .font(Tokens.sectionHeaderFont)
                .foregroundStyle(Tokens.secondaryText)
            Text(value)
                .font(.body)
                .textSelection(.enabled)
        }
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
