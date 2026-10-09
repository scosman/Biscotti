import AppCore
import Foundation

// MARK: - Audio file import (File menu, toolbar button, drag-and-drop)

/// Every shell entry point funnels into `AppCore.importAudioFiles(at:)`;
/// this extension only adds the panel/drop front doors and the alert state.
public extension AppShellViewModel {
    /// File menu ("Import Audio File...") and toolbar button: choose one or
    /// more files, then import them in order. Cancelling does nothing.
    /// Ignored while onboarding takes over the window.
    func importAudioFiles() async {
        guard !showOnboarding else { return }
        let urls = presentAudioOpenPanel()
        guard !urls.isEmpty else { return }
        await core.importAudioFiles(at: urls)
    }

    /// Whether a drag carrying `urls` should be accepted: at least one
    /// audio/video file, and not during onboarding.
    func canAcceptDrop(_ urls: [URL]) -> Bool {
        !showOnboarding && urls.contains(where: AudioImportSupport.isSupported)
    }

    /// Imports dropped files. Unsupported ones are not filtered out here:
    /// the core reports them in the same "Couldn't import" alert and
    /// creates no meeting for them.
    func importDroppedFiles(_ urls: [URL]) async {
        guard !showOnboarding, !urls.isEmpty else { return }
        await core.importAudioFiles(at: urls)
    }

    /// The pending "Couldn't import" alert, if any import failed.
    var audioImportAlert: AudioImportAlert? {
        AudioImportAlert(failures: core.audioImportFailures)
    }

    /// Dismisses the "Couldn't import" alert.
    func dismissAudioImportAlert() {
        core.dismissAudioImportFailures()
    }
}
