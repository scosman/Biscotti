import Automation
import DesignSystem
import SwiftUI

/// What re-transcribing does to exports, and the notice.
struct ExportBehaviorControls: View {
    let store: AutomationSettingsStore

    var body: some View {
        VStack(alignment: .leading, spacing: Tokens.spacingXS) {
            Picker("After re-transcribing", selection: Binding(
                get: { store.settings.reTranscribeExport },
                set: { value in store.update { $0.reTranscribeExport = value } }
            )) {
                ForEach(ReTranscribeExportBehavior.allCases) { behavior in
                    Text(behavior.title).tag(behavior)
                }
            }
            Text("Keeping the old export renames it \u{201C}\u{2026} (before <date>).md\u{201D}; replacing overwrites the file for that meeting only.")
                .font(Tokens.metadataFont)
                .foregroundStyle(Tokens.secondaryText)
        }
        Toggle("Notify me when an export is written", isOn: Binding(
            get: { store.settings.notifyOnExport },
            set: { value in store.update { $0.notifyOnExport = value } }
        ))
    }
}
