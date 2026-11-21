import Automation
import SwiftUI

/// Asks what to do with the automatic export before a
/// re-transcription starts.
struct ReExportDialog: ViewModifier {
    @Bindable var viewModel: MeetingDetailViewModel

    private var hasExistingFile: Bool {
        viewModel.reExportPrompt?.hasExistingFile == true
    }

    func body(content: Content) -> some View {
        content.confirmationDialog(
            hasExistingFile
                ? "Replace the exported file after re-transcribing?"
                : "Export after re-transcribing?",
            isPresented: Binding(
                get: { viewModel.reExportPrompt != nil },
                set: { if !$0 { viewModel.reExportPrompt = nil } }
            ),
            titleVisibility: .visible
        ) {
            if hasExistingFile {
                Button("Re-transcribe and Replace Export") {
                    viewModel.reTranscribe(exportChoice: .replace)
                }
                Button("Re-transcribe and Keep Old Export") {
                    viewModel.reTranscribe(exportChoice: .keepBoth)
                }
            } else {
                Button("Re-transcribe and Export") {
                    viewModel.reTranscribe(exportChoice: .replace)
                }
            }
            Button("Re-transcribe Without Exporting") {
                viewModel.reTranscribe(exportChoice: .skip)
            }
            Button("Cancel", role: .cancel) {
                viewModel.reExportPrompt = nil
            }
        } message: {
            if hasExistingFile {
                Text("This meeting is already exported. Keeping the old export renames it with \"(before <date>)\" so both stay.")
            } else {
                Text("Automatic export is on.")
            }
        }
    }
}

/// Asks whether to update the export after speaker names
/// change by hand (when the re-export setting is "Ask each time").
struct NameChangeExportDialog: ViewModifier {
    @Bindable var viewModel: MeetingDetailViewModel

    func body(content: Content) -> some View {
        content.confirmationDialog(
            "Update the exported file with the new names?",
            isPresented: $viewModel.nameExportPrompt,
            titleVisibility: .visible
        ) {
            Button("Replace Export") { viewModel.answerNameExport(.replace) }
            Button("Keep Old Export Too") { viewModel.answerNameExport(.keepBoth) }
            Button("Not Now", role: .cancel) { viewModel.answerNameExport(.skip) }
        } message: {
            Text("The export still has the old speaker names. Keeping the old export renames it with \"(before <date>)\".")
        }
    }
}
