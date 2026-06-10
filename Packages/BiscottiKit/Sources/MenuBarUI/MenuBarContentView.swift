import AppCore
import Calendar
import DataStore
import DesignSystem
import SwiftUI

/// The popover body content of the `MenuBarExtra`.
///
/// Shows recording section (Start / elapsed+Stop), upcoming events,
/// recent meetings, and Open/Quit actions.
public struct MenuBarContentView: View {
    @Bindable var viewModel: MenuBarViewModel

    public init(viewModel: MenuBarViewModel) {
        self.viewModel = viewModel
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Recording section
            if viewModel.isRecording {
                recordingSection
            } else {
                Button("Start Recording") {
                    Task { await viewModel.startRecording() }
                }
                .padding(.horizontal, Tokens.spacingSM)
                .padding(.vertical, Tokens.spacingXS)
            }

            Divider()
                .padding(.vertical, Tokens.spacingXS)

            // Upcoming
            if !viewModel.upcomingEvents.isEmpty {
                upcomingSection
                Divider()
                    .padding(.vertical, Tokens.spacingXS)
            }

            // Recent
            if !viewModel.recentMeetings.isEmpty {
                recentSection
                Divider()
                    .padding(.vertical, Tokens.spacingXS)
            }

            // Footer
            Button("Open Biscotti") {
                viewModel.openApp()
            }
            .padding(.horizontal, Tokens.spacingSM)
            .padding(.vertical, Tokens.spacingXS)

            Button("Quit") {
                viewModel.quit()
            }
            .padding(.horizontal, Tokens.spacingSM)
            .padding(.vertical, Tokens.spacingXS)
        }
        .frame(width: 260)
        .padding(Tokens.spacingSM)
    }

    // MARK: - Sections

    private var recordingSection: some View {
        HStack {
            Circle()
                .fill(.red)
                .frame(width: 8, height: 8)
            Text(viewModel.elapsedText)
                .monospacedDigit()
            Spacer()
            Button("Stop") {
                Task { await viewModel.stopRecording() }
            }
        }
        .padding(.horizontal, Tokens.spacingSM)
        .padding(.vertical, Tokens.spacingXS)
    }

    private var upcomingSection: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("Upcoming")
                .font(Tokens.metadataFont)
                .foregroundStyle(.secondary)
                .padding(.horizontal, Tokens.spacingSM)

            ForEach(viewModel.upcomingEvents) { event in
                UpcomingEventRow(
                    title: event.title,
                    timeText: MenuBarViewModel.relativeTimeText(
                        event.start
                    ),
                    platformBadge: event.conferencePlatform
                )
                .padding(.horizontal, Tokens.spacingSM)
                .padding(.vertical, 2)
            }
        }
    }

    private var recentSection: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("Recent")
                .font(Tokens.metadataFont)
                .foregroundStyle(.secondary)
                .padding(.horizontal, Tokens.spacingSM)

            ForEach(viewModel.recentMeetings) { meeting in
                Button {
                    viewModel.openApp(meetingID: meeting.id)
                } label: {
                    HStack {
                        Text(meeting.title)
                            .lineLimit(1)
                        Spacer()
                        Text(Self.relativeDate(meeting.date))
                            .font(Tokens.metadataFont)
                            .foregroundStyle(.secondary)
                    }
                }
                .buttonStyle(.plain)
                .padding(.horizontal, Tokens.spacingSM)
                .padding(.vertical, 2)
            }

            Button("See all\u{2026}") {
                viewModel.seeAll()
            }
            .font(Tokens.metadataFont)
            .padding(.horizontal, Tokens.spacingSM)
            .padding(.vertical, 2)
        }
    }

    // MARK: - Formatting

    private static func relativeDate(_ date: Date) -> String {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .abbreviated
        return formatter.localizedString(for: date, relativeTo: Date())
    }
}
