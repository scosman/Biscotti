import AppCore
import AppKit
import Automation
import DesignSystem
import SwiftUI

/// Recording Automation, Retention and Automatic Export
/// sections. A separate view (not a `SettingsView` extension) so it can own
/// its own `@State`; it is placed inside SettingsView's `Form`, which
/// flattens the returned sections.
struct AutomationSettingsSections: View {
    let core: AppCore
    @State private var exportAllInFlight = false
    @State private var exportAllResult: String?
    @State private var addTargetError: String?

    /// Sentinel tag for "Keep forever" in the retention pickers.
    private static let keepForever = -1

    private var store: AutomationSettingsStore {
        core.automation
    }

    private var settings: AutomationSettings {
        store.settings
    }

    var body: some View {
        recordingSection
        MeetingCaptureSettingsSection(core: core)
        MicrophonePrioritySection(core: core)
        retentionSection
        exportSection
    }

    // MARK: - Recording Automation

    private var recordingSection: some View {
        Section("Recording Automation") {
            VStack(alignment: .leading, spacing: Tokens.spacingXS) {
                Picker("When a meeting starts", selection: modeBinding) {
                    ForEach(RecordingMode.allCases) { mode in
                        Text(mode.title).tag(mode)
                    }
                }
                caption(settings.recordingMode.detail)
            }
            VStack(alignment: .leading, spacing: Tokens.spacingXS) {
                Toggle("Auto-record meetings in web browsers and Ferdium", isOn: binding(\.autoRecordInBrowsers))
                    .disabled(settings.recordingMode != .automatic)
                caption("Off: browser meetings get the Record notification instead, since any site using the mic looks like a meeting.")
            }
            VStack(alignment: .leading, spacing: Tokens.spacingXS) {
                Toggle("Stop recording when the screen locks", isOn: binding(\.stopOnScreenLock))
                caption("The recording is saved and processed as usual.")
            }
        }
    }

    private var modeBinding: Binding<RecordingMode> {
        Binding(
            get: { settings.recordingMode },
            set: { mode in Task { await core.setRecordingMode(mode) } }
        )
    }

    // MARK: - Retention

    private var retentionSection: some View {
        Section("Retention") {
            VStack(alignment: .leading, spacing: Tokens.spacingXS) {
                retentionPicker("Delete audio", choices: RetentionPolicy.audioChoices, keyPath: \.audioRetentionDays)
                caption("Removes the recording files only. The transcript, summary and notes stay. Speaker names can't be corrected afterward.")
            }
            VStack(alignment: .leading, spacing: Tokens.spacingXS) {
                retentionPicker(
                    "Delete meetings", choices: RetentionPolicy.meetingChoices, keyPath: \.meetingRetentionDays
                )
                Toggle("Only delete meetings that were exported", isOn: requireExportBinding)
                if let warning = retentionWarning {
                    caption(warning)
                }
            }
            HStack {
                caption(store.lastRetentionSummary ?? "Cleanup runs at launch, after each meeting is processed, and every 6 hours.")
                Spacer()
                Button("Clean Up Now") {
                    Task { await core.runRetentionPass() }
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }
        }
    }

    private var retentionWarning: String? {
        let retention = settings.retention
        guard retention.meetingRetentionDays != nil, retention.requireExportBeforeDelete else { return nil }
        return settings.enabledExportTargets.isEmpty
            ? "No export target is enabled, so no meetings will be deleted."
            : "Meetings are deleted only after exporting to every enabled target."
    }

    private func retentionPicker(
        _ title: String,
        choices: [Int?],
        keyPath: WritableKeyPath<RetentionPolicy, Int?>
    ) -> some View {
        Picker(title, selection: Binding(
            get: { settings.retention[keyPath: keyPath] ?? Self.keepForever },
            set: { value in
                store.update { $0.retention[keyPath: keyPath] = value == Self.keepForever ? nil : value }
            }
        )) {
            ForEach(choices, id: \.self) { days in
                Text(RetentionPolicy.label(forDays: days)).tag(days ?? Self.keepForever)
            }
        }
    }

    private var requireExportBinding: Binding<Bool> {
        Binding(
            get: { settings.retention.requireExportBeforeDelete },
            set: { value in store.update { $0.retention.requireExportBeforeDelete = value } }
        )
    }

    // MARK: - Automatic Export

    private var exportSection: some View {
        Section("Automatic Export") {
            caption("After a meeting is transcribed and summarized, its title, summary, notes and transcript are written as Markdown to each enabled target.")
            ForEach(settings.exportTargets) { target in
                ExportTargetRow(target: target, store: store)
            }
            HStack {
                Button("Add Folder\u{2026}") { addTarget(kind: .folder) }
                Button("Add Git Repository\u{2026}") { addTarget(kind: .gitRepository) }
                Spacer()
                if exportAllInFlight {
                    ProgressView().controlSize(.small)
                } else {
                    Button("Export All Now") { exportAll() }
                        .disabled(settings.enabledExportTargets.isEmpty)
                }
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            if let message = addTargetError ?? exportAllResult {
                caption(message)
            }
            // Re-transcription behavior and export notices.
            ExportBehaviorControls(store: store)
            if let status = store.lastExportStatus {
                exportStatusRow(status)
            }
        }
    }

    private func exportStatusRow(_ status: ExportStatus) -> some View {
        let when = status.date.formatted(date: .abbreviated, time: .shortened)
        let headline = status.failures.isEmpty
            ? "Last export: \u{201C}\(status.meetingTitle)\u{201D} on \(when)."
            : "Last export of \u{201C}\(status.meetingTitle)\u{201D} on \(when) had problems:"
        return VStack(alignment: .leading, spacing: Tokens.spacingXS) {
            caption(headline)
            if !status.detail.isEmpty, status.failures.isEmpty {
                caption(status.detail)
            }
            ForEach(status.failures, id: \.self) { failure in
                Text(failure)
                    .font(Tokens.metadataFont)
                    .foregroundStyle(.red)
                    .textSelection(.enabled)
            }
        }
    }

    private func addTarget(kind: ExportTarget.Kind) {
        addTargetError = nil
        guard let url = Self.chooseDirectory(
            prompt: kind == .folder ? "Export Here" : "Use Repository"
        ) else { return }
        if kind == .gitRepository,
           !FileManager.default.fileExists(atPath: url.appendingPathComponent(".git").path)
        {
            addTargetError = "\(url.path) is not the root of a git repository (no .git folder)."
            return
        }
        let target = ExportTarget(
            name: url.lastPathComponent,
            kind: kind,
            path: url.path,
            subfolder: kind == .gitRepository ? ExportTarget.defaultGitSubfolder : ""
        )
        store.update { $0.exportTargets.append(target) }
    }

    private func exportAll() {
        exportAllInFlight = true
        exportAllResult = nil
        Task {
            let count = await core.exportAllMeetings()
            exportAllResult = "Exported \(count) meeting(s) to every enabled target."
            exportAllInFlight = false
        }
    }

    @MainActor
    private static func chooseDirectory(prompt: String) -> URL? {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = prompt
        return panel.runModal() == .OK ? panel.url : nil
    }

    // MARK: - Helpers

    private func binding(_ keyPath: WritableKeyPath<AutomationSettings, Bool>) -> Binding<Bool> {
        Binding(
            get: { settings[keyPath: keyPath] },
            set: { value in store.update { $0[keyPath: keyPath] = value } }
        )
    }

    private func caption(_ text: String) -> some View {
        Text(text)
            .font(Tokens.metadataFont)
            .foregroundStyle(Tokens.secondaryText)
    }
}

/// One export target: enable toggle, location, git options, remove.
private struct ExportTargetRow: View {
    let target: ExportTarget
    let store: AutomationSettingsStore

    var body: some View {
        VStack(alignment: .leading, spacing: Tokens.spacingXS) {
            HStack {
                Toggle(isOn: update(\.isEnabled)) {
                    Text("\(target.name) (\(target.kind.title))")
                }
                Spacer()
                Button("Remove", role: .destructive) {
                    store.update { settings in settings.exportTargets.removeAll { $0.id == target.id } }
                }
                .buttonStyle(.borderless)
                .controlSize(.small)
            }
            Text(target.outputDirectory.path)
                .font(Tokens.metadataFont)
                .foregroundStyle(Tokens.secondaryText)
                .textSelection(.enabled)
            if target.kind == .gitRepository {
                TextField("Subfolder", text: update(\.subfolder), prompt: Text(ExportTarget.defaultGitSubfolder))
                Toggle("Push after each commit", isOn: update(\.pushAfterCommit))
            }
        }
    }

    private func update<Value>(_ keyPath: WritableKeyPath<ExportTarget, Value>) -> Binding<Value> {
        Binding(
            get: { target[keyPath: keyPath] },
            set: { value in
                store.update { settings in
                    guard let index = settings.exportTargets.firstIndex(where: { $0.id == target.id }) else { return }
                    settings.exportTargets[index][keyPath: keyPath] = value
                }
            }
        )
    }
}
