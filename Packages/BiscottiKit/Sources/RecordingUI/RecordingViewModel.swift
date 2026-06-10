import AppCore
import Foundation
import Permissions
import Recording

/// View model for the active-recording screen.
///
/// Projects `AppCore.recording.state` into display-ready values and
/// forwards stop actions to `AppCore.stopRecording()`.
@MainActor @Observable
public final class RecordingViewModel {
    private let core: AppCore

    public init(core: AppCore) {
        self.core = core
    }

    // MARK: - Projected state

    /// Whether a recording is in progress.
    public var isRecording: Bool {
        core.recording.state.isRecording
    }

    /// The formatted elapsed time (e.g. "02:14").
    public var elapsedText: String {
        Self.formatElapsed(core.recording.state.elapsed)
    }

    /// The title of the current meeting being recorded.
    public var meetingTitle: String? {
        guard let meetingID = core.recording.state.meetingID else { return nil }
        return core.summaries.first(where: { $0.id == meetingID })?.title
    }

    /// Whether the system-audio denial banner should be shown.
    public var showSystemAudioWarning: Bool {
        core.recording.systemAudioWarning
    }

    /// The URL to open System Settings for system audio fix.
    public var systemAudioSettingsURL: URL {
        core.permissions.settingsURL(for: .systemAudio)
    }

    // MARK: - Actions

    /// Stops the current recording.
    public func stop() async {
        await core.stopRecording()
    }

    // MARK: - Formatting

    /// Formats a time interval as "MM:SS" or "H:MM:SS" for large values.
    static func formatElapsed(_ elapsed: TimeInterval) -> String {
        let totalSeconds = Int(elapsed)
        let hours = totalSeconds / 3600
        let minutes = (totalSeconds % 3600) / 60
        let seconds = totalSeconds % 60

        if hours > 0 {
            return String(format: "%d:%02d:%02d", hours, minutes, seconds)
        }
        return String(format: "%02d:%02d", minutes, seconds)
    }
}
