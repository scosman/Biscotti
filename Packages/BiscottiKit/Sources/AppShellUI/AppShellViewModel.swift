import AppCore
import Foundation
import MeetingDetailUI
import MeetingListUI
import RecordingUI

/// View model for the app shell (NavigationSplitView wrapper).
///
/// Owns the sidebar state (Record button, recording indicator) and routes
/// the detail pane based on `AppCore.route`.
///
/// Child view models (`meetingListViewModel`, `recordingViewModel`,
/// `meetingDetailViewModel(for:)`) are created once and cached so they
/// survive SwiftUI re-evaluations. This prevents `@State` resets in
/// child views (e.g. the recording dot-blink animation).
@MainActor @Observable
public final class AppShellViewModel {
    private let core: AppCore

    // MARK: - Stable child view models

    /// The sidebar meeting-list view model (created once, never replaced).
    public let meetingListViewModel: MeetingListViewModel

    /// The recording-screen view model (created once, never replaced).
    public let recordingViewModel: RecordingViewModel

    /// Cached meeting-detail view model, keyed by meeting ID.
    /// Replaced only when the selected meeting changes.
    private var cachedDetailMeetingID: UUID?
    private var cachedDetailViewModel: MeetingDetailViewModel?

    public init(core: AppCore) {
        self.core = core
        meetingListViewModel = MeetingListViewModel(core: core)
        recordingViewModel = RecordingViewModel(core: core)
    }

    /// Returns a stable `MeetingDetailViewModel` for the given meeting ID.
    /// Re-creates only when the ID changes.
    public func meetingDetailViewModel(for meetingID: UUID) -> MeetingDetailViewModel {
        if let cached = cachedDetailViewModel, cachedDetailMeetingID == meetingID {
            return cached
        }
        let viewModel = MeetingDetailViewModel(core: core, meetingID: meetingID)
        cachedDetailMeetingID = meetingID
        cachedDetailViewModel = viewModel
        return viewModel
    }

    /// The underlying AppCore for child view models to consume.
    public var appCore: AppCore {
        core
    }

    // MARK: - Sidebar state

    /// Whether the Record button should be disabled (recording in progress).
    public var recordButtonDisabled: Bool {
        core.recording.state.isRecording
    }

    /// Whether to show the recording indicator in the sidebar.
    public var showRecordingIndicator: Bool {
        core.recording.state.isRecording
    }

    /// Formatted elapsed time for the sidebar recording indicator.
    public var recordingElapsedText: String {
        let elapsed = core.recording.state.elapsed
        let totalSeconds = Int(elapsed)
        let minutes = (totalSeconds % 3600) / 60
        let seconds = totalSeconds % 60
        return String(format: "%d:%02d", minutes, seconds)
    }

    // MARK: - Detail routing

    /// The current route determining which detail view to show.
    public var route: Route {
        core.route
    }

    // MARK: - Actions

    /// Starts a new recording session.
    public func startRecording() async {
        await core.startRecording()
    }

    /// Navigates to the recording screen (when tapping the recording indicator).
    public func showRecording() {
        core.navigateToRecording()
    }

    /// Called on app launch to run recovery and load data.
    public func onLaunch() async {
        await core.onLaunch()
    }
}
