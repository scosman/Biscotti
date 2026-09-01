import DesignSystem
import SwiftUI

// MARK: - Import/Export section (functional spec §6)

extension SettingsView {
    /// "Learn more" target: the user-facing guide shipped in the repo
    /// (`App/ImportingExporting.md`), read on GitHub — the same
    /// treatment as the MCP row's help link.
    static let importExportGuideURL = URL(
        string: "https://github.com/scosman/Biscotti/blob/main/App/ImportingExporting.md"
    )!

    static let importRowTitle = "Import Meetings"
    static let importRowSubtitle = "Import meetings from other apps, via CSV."
    static let exportRowTitle = "Export Meetings"
    static let exportRowSubtitle = "Export all meetings to CSV."
    static let learnMoreTitle = "Learn more"

    var importExportSection: some View {
        Section(Self.sectionTitles[5]) {
            importMeetingsRow
            exportMeetingsRow
        }
        .alert(
            viewModel.importAlert?.title ?? "",
            isPresented: importExportAlertBinding,
            presenting: viewModel.importAlert
        ) { state in
            alertButtons(for: state)
        } message: { state in
            Text(state.body)
        }
    }

    private var importMeetingsRow: some View {
        HStack {
            VStack(alignment: .leading, spacing: Tokens.spacingXS) {
                Text(Self.importRowTitle)
                learnMoreSubtitle(Self.importRowSubtitle)
            }

            Spacer()

            if viewModel.importInFlight {
                ProgressView()
                    .controlSize(.small)
            } else {
                Button("Import") {
                    Task { await viewModel.beginImport() }
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .disabled(viewModel.importExportBusy)
            }
        }
    }

    private var exportMeetingsRow: some View {
        HStack {
            VStack(alignment: .leading, spacing: Tokens.spacingXS) {
                Text(Self.exportRowTitle)
                learnMoreSubtitle(Self.exportRowSubtitle)
            }

            Spacer()

            if viewModel.exportInFlight {
                ProgressView()
                    .controlSize(.small)
            } else {
                Button("Export") {
                    Task { await viewModel.beginExport() }
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .disabled(viewModel.importExportBusy)
            }
        }
    }

    /// Subtitle with an inline "Learn more" link. Colored directly on
    /// the label, not via `.tint`: link and Form-row styling resolve
    /// their own (system blue) accent and ignore a tint set at this
    /// scope — the same construction as the MCP row's "How to connect".
    private func learnMoreSubtitle(_ text: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: Tokens.spacingSM) {
            Text(text)
                .font(Tokens.metadataFont)
                .foregroundStyle(Tokens.secondaryText)
            Button {
                NSWorkspace.shared.open(Self.importExportGuideURL)
            } label: {
                Text(Self.learnMoreTitle)
                    .font(Tokens.metadataFont)
                    .foregroundStyle(.sage)
            }
            .buttonStyle(.borderless)
            .controlSize(.small)
        }
    }

    // MARK: - Alert

    @ViewBuilder
    private func alertButtons(for state: ImportAlertState) -> some View {
        switch state {
        case .blocked, .result, .failure:
            // The cancel role lets Escape dismiss a single-button alert.
            Button("OK", role: .cancel) { viewModel.dismissImportAlert() }

        case .review:
            // Cancel is the default action and Continue is secondary
            // (functional spec §3.3). This deliberately differs from the
            // MCP row's confirm alert, whose *confirm* button is the
            // default action — here the spec makes Cancel the safe
            // default.
            Button("Cancel", role: .cancel) {
                viewModel.cancelImportReview()
            }
            .keyboardShortcut(.defaultAction)
            Button("Continue") {
                Task { await viewModel.confirmImport() }
            }

        #if DEBUG
            case .confirmDeleteImported:
                // Never presented through this modifier (the binding
                // excludes it); the branch keeps the switch exhaustive.
                Button("OK", role: .cancel) { viewModel.dismissImportAlert() }
        #endif
        }
    }

    /// Presents every import/export alert except the debug delete
    /// confirmation, which the Debug section's own modifier presents.
    private var importExportAlertBinding: Binding<Bool> {
        Binding(
            get: {
                guard let state = viewModel.importAlert else { return false }
                #if DEBUG
                    return !state.isDeleteConfirmation
                #else
                    return true
                #endif
            },
            set: { shown in
                if !shown { viewModel.dismissImportAlert() }
            }
        )
    }
}

// MARK: - Debug: Delete Imported Meetings row (functional spec §6.1)

#if DEBUG
    extension SettingsView {
        /// Debug-only bulk delete of imported meetings, styled like its
        /// Debug-section neighbours. Never compiled into release builds.
        var deleteImportedMeetingsRow: some View {
            Button {
                Task { await viewModel.promptDeleteImportedMeetings() }
            } label: {
                Label("Delete Imported Meetings", systemImage: "trash")
            }
            .foregroundStyle(.sage)
            .alert(
                viewModel.importAlert?.title ?? "",
                isPresented: deleteImportedAlertBinding,
                presenting: viewModel.importAlert
            ) { _ in
                // Cancel is the default action (functional spec §6.1),
                // matching the review alert (§3.3).
                Button("Cancel", role: .cancel) {
                    viewModel.dismissImportAlert()
                }
                .keyboardShortcut(.defaultAction)
                Button("Delete", role: .destructive) {
                    Task { await viewModel.confirmDeleteImportedMeetings() }
                }
            } message: { state in
                Text(state.body)
            }
        }

        /// Presents only the debug delete confirmation — the Import/Export
        /// section's modifier handles every other state.
        private var deleteImportedAlertBinding: Binding<Bool> {
            Binding(
                get: { viewModel.importAlert?.isDeleteConfirmation == true },
                set: { shown in
                    if !shown { viewModel.dismissImportAlert() }
                }
            )
        }
    }
#endif
