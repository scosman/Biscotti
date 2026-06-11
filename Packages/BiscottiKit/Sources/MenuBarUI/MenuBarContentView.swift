import AppCore
import Calendar
import DataStore
import DesignSystem
import SwiftUI

/// The native-menu body content of the `MenuBarExtra`.
///
/// Uses `.menu`-style `MenuBarExtra`, so all content must be
/// menu-compatible: `Button`, `Divider`, `Text` (disabled items).
/// No custom views, no VStack layouts.
public struct MenuBarContentView: View {
    @Bindable var viewModel: MenuBarViewModel

    public init(viewModel: MenuBarViewModel) {
        self.viewModel = viewModel
    }

    public var body: some View {
        // Recording section
        recordingSection

        Divider()

        // Upcoming
        if !viewModel.upcomingEvents.isEmpty {
            upcomingSection
            Divider()
        }

        // Recent
        if !viewModel.recentMeetings.isEmpty {
            recentSection
            Divider()
        }

        // Footer
        Button("Open Biscotti") {
            viewModel.openApp()
        }

        Button("Quit") {
            viewModel.quit()
        }
    }

    // MARK: - Sections

    @ViewBuilder
    private var recordingSection: some View {
        if viewModel.isRecording {
            Button("Stop Recording (\(viewModel.elapsedText))") {
                Task { await viewModel.stopRecording() }
            }
        } else {
            Button("Start Recording") {
                Task { await viewModel.startRecording() }
            }
        }
    }

    @ViewBuilder
    private var upcomingSection: some View {
        Text("Upcoming")

        ForEach(viewModel.upcomingEvents) { event in
            Button {
                viewModel.openEvent(event.id)
            } label: {
                Text(
                    "\(event.title) \u{2014} \(MenuBarViewModel.relativeTimeText(event.start))"
                )
            }
        }
    }

    @ViewBuilder
    private var recentSection: some View {
        Text("Recent")

        ForEach(viewModel.recentMeetings) { meeting in
            Button {
                viewModel.openApp(meetingID: meeting.id)
            } label: {
                Text(
                    "\(meeting.title) \u{2014} \(Self.relativeDate(meeting.date))"
                )
            }
        }

        // TODO(see-all): add a 'See All' menu entry once a full upcoming/recent list page exists
    }

    // MARK: - Formatting

    private static func relativeDate(_ date: Date) -> String {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .abbreviated
        return formatter.localizedString(for: date, relativeTo: Date())
    }
}
