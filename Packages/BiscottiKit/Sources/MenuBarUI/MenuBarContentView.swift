import AppCore
import Automation
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
        // Missing permissions open the app's prompt.
        if viewModel.needsPermissions {
            Button("\u{26A0}\u{FE0E} Permissions Needed\u{2026}") {
                viewModel.openApp()
            }
            Divider()
        }

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

        // Meeting-window capture status while recording.
        uiCaptureStatus

        // What the last automatic export did.
        if let export = viewModel.lastExportLine {
            Text(export)
            Divider()
        }

        // Footer
        Button("Open Biscotti") {
            viewModel.openApp()
        }

        // Straight to Settings.
        Button("Settings\u{2026}") {
            viewModel.openSettings()
        }

        Button("Quit Biscotti") {
            viewModel.quit()
        }
    }

    // MARK: - Sections

    @ViewBuilder
    private var recordingSection: some View {
        // Status line: elapsed timer while recording, otherwise the mode.
        Text(viewModel.statusText)

        if viewModel.isRecording {
            Button {
                Task { await viewModel.stopRecording() }
            } label: {
                Label(
                    "Stop Recording (\(viewModel.elapsedText))",
                    systemImage: viewModel.recordActionIcon
                )
            }
        } else {
            Button {
                Task { await viewModel.startRecording() }
            } label: {
                Label(
                    "Record Now",
                    systemImage: viewModel.recordActionIcon
                )
            }
        }

        // Mode picker, rendered by the menu as a submenu
        // with a checkmark on the current mode.
        Picker("Recording Mode", selection: recordingModeBinding) {
            ForEach(viewModel.recordingModes) { mode in
                Text(mode.title).tag(mode)
            }
        }
    }

    /// One status line while a recording captures the meeting
    /// window. Everything else about the capture lives in Settings.
    @ViewBuilder
    private var uiCaptureStatus: some View {
        if viewModel.isRecording {
            Text(viewModel.uiCaptureStatusLine)
        }
    }

    private var recordingModeBinding: Binding<RecordingMode> {
        Binding(
            get: { viewModel.recordingMode },
            set: { mode in Task { await viewModel.setRecordingMode(mode) } }
        )
    }

    @ViewBuilder
    private var upcomingSection: some View {
        Text("Upcoming")

        ForEach(viewModel.upcomingEvents) { event in
            Button {
                viewModel.openEvent(event.id)
            } label: {
                Text(
                    "\(event.title) \u{2014} \(viewModel.tickTimeText(for: event))"
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
