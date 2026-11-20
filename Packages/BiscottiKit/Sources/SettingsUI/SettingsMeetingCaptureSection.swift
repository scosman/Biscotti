import AppCore
import AppKit
import Automation
import DesignSystem
import SwiftUI
import UICapture

/// The meeting-window capture and speaker naming settings.
struct MeetingCaptureSettingsSection: View {
    let core: AppCore
    /// The capture folder lives in UserDefaults, outside observation.
    @State private var folderRefresh = 0

    private static let keepChoices: [(days: Int, title: String)] = [
        (7, "After 7 days"), (30, "After 30 days"), (90, "After 90 days"), (0, "Never")
    ]

    private var store: AutomationSettingsStore {
        core.automation
    }

    private var settings: AutomationSettings {
        store.settings
    }

    var body: some View {
        Section("Meeting Window Capture and Speaker Names") {
            VStack(alignment: .leading, spacing: Tokens.spacingXS) {
                Toggle("Capture the meeting window during every recording", isOn: binding(\.captureMeetingUI))
                Toggle("Offer to turn on live captions in meetings", isOn: binding(\.offerCaptions))
                    .help("Captions greatly improve speaker identification and transcription. Biscotti asks once per meeting when they're off.")
                caption("Starts and stops with the recording. Reads participant names and who is highlighted as speaking through Accessibility; it never takes screenshots.")
            }
            VStack(alignment: .leading, spacing: Tokens.spacingXS) {
                Text("Apps to capture")
                ForEach(CaptureAppChoices.all) { choice in
                    Toggle(choice.name, isOn: appBinding(choice.id))
                        .padding(.leading, Tokens.spacingSM)
                }
                caption("Ferdium and browsers are read only while they're on a call, and are added if they join after the recording starts.")
            }
            .disabled(!settings.captureMeetingUI)
            HStack {
                VStack(alignment: .leading, spacing: Tokens.spacingXS) {
                    Text("Capture files")
                    caption(folderPath)
                }
                Spacer()
                Button("Change\u{2026}") {
                    core.uiCapture.chooseFolderAgain()
                    folderRefresh += 1
                }
                Button("Show") {
                    let folder = core.uiCapture.folder ?? UICaptureController.defaultFolder
                    NSWorkspace.shared.activateFileViewerSelecting([folder])
                }
            }
            Picker("Delete capture files", selection: keepBinding) {
                ForEach(Self.keepChoices, id: \.days) { choice in
                    Text(choice.title).tag(choice.days)
                }
            }
            VStack(alignment: .leading, spacing: Tokens.spacingXS) {
                Toggle("Name speakers after each meeting", isOn: binding(\.nameSpeakers))
                caption("Your lines come from your microphone track; other voices are named from the meeting-window capture. Voices without clear evidence stay \"Speaker N\" for AI naming. Re-transcribe an older meeting to name its speakers.")
            }
            TextField("Your name in transcripts", text: nameBinding, prompt: Text(NSFullUserName()))
                .disabled(!settings.nameSpeakers)
            if core.uiCapture.isCapturing {
                caption("Capturing now, with the current recording.")
            } else if let message = core.uiCapture.lastMessage {
                caption("Last capture: \(message)")
            }
            if let report = store.lastNamingReport {
                caption("Last meeting: \(report)")
            }
        }
    }

    private var folderPath: String {
        _ = folderRefresh
        let folder = core.uiCapture.folder ?? UICaptureController.defaultFolder
        return (folder.path as NSString).abbreviatingWithTildeInPath
    }

    private func binding(_ keyPath: WritableKeyPath<AutomationSettings, Bool>) -> Binding<Bool> {
        Binding(
            get: { settings[keyPath: keyPath] },
            set: { value in store.update { $0[keyPath: keyPath] = value } }
        )
    }

    private func appBinding(_ bundleID: String) -> Binding<Bool> {
        Binding(
            get: { !settings.captureExcludedApps.contains(bundleID) },
            set: { included in
                store.update { settings in
                    settings.captureExcludedApps.removeAll { $0 == bundleID }
                    if !included { settings.captureExcludedApps.append(bundleID) }
                }
            }
        )
    }

    private var keepBinding: Binding<Int> {
        Binding(
            get: { settings.captureKeepDays },
            set: { days in store.update { $0.captureKeepDays = days } }
        )
    }

    private var nameBinding: Binding<String> {
        Binding(
            get: { settings.transcriptName },
            set: { name in store.update { $0.transcriptName = name } }
        )
    }

    private func caption(_ text: String) -> some View {
        Text(text)
            .font(Tokens.metadataFont)
            .foregroundStyle(Tokens.secondaryText)
    }
}
