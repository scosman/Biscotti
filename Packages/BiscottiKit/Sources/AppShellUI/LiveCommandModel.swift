import AppCore
import LiveTranscriptionService
import Observation

/// View > Show / Hide Live Transcript (⌘T). The app delegate owns one and
/// gives it the core once the core is built.
@MainActor @Observable
public final class LiveCommandModel {
    public var core: AppCore?
    /// Brings the main window forward; the app delegate sets it.
    @ObservationIgnored public var showMainWindow: (@MainActor () -> Void)?

    /// Nonisolated so the app delegate can create it as a stored property.
    public nonisolated init() {}

    public init(core: AppCore?) {
        self.core = core
    }

    /// "Hide Live Transcript" while the recording screen shows the open
    /// drawer, otherwise "Show Live Transcript".
    public var title: String {
        guard let core, core.recording.state.isRecording, core.route == .recording,
              core.liveTranscription.isDrawerExpanded
        else { return "Show Live Transcript" }
        return "Hide Live Transcript"
    }

    /// Enabled whenever the recording screen shows the toggle: a recording
    /// runs with live transcription on, available or not, so ⌘T also opens
    /// the drawer that offers the model download.
    public var isEnabled: Bool {
        guard let core else { return false }
        return core.recording.state.isRecording && core.liveTranscription.isVisible
    }

    /// On the recording screen, shows or hides the drawer. On another screen,
    /// brings the recording screen forward with the drawer shown.
    public func toggle() {
        guard let core, isEnabled else { return }
        if core.route == .recording {
            core.liveTranscription.toggleDrawer()
        } else {
            showMainWindow?()
            core.navigateToRecording()
            core.liveTranscription.isDrawerExpanded = true
        }
    }
}
