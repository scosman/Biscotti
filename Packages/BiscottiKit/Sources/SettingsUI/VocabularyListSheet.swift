import DesignSystem
import SwiftUI

/// Editor sheet for the user's custom vocabulary list. Modeled on
/// `SummaryPromptSheet`: kicker, serif title, 13pt subtitle, padded
/// with `Tokens.spacingLG`.
struct VocabularyListSheet: View {
    @Bindable var viewModel: SettingsViewModel
    @Environment(\.dismiss) private var dismiss

    @State private var newTerm = ""
    @State private var validationError: VocabularyTermError?
    @FocusState private var addFieldFocused: Bool

    /// Tracks an in-progress inline edit so validation errors can
    /// revert the text field to the previous value.
    @State private var editingIndex: Int?
    @State private var editingText: String = ""

    var body: some View {
        VStack(alignment: .leading, spacing: Tokens.spacingMD) {
            headerSection
            addTermField
            validationMessage
            termList
            Divider()
            footerSection
        }
        .padding(Tokens.spacingLG)
        .frame(width: 520)
        .onAppear { addFieldFocused = true }
    }

    // MARK: - Header

    private var headerSection: some View {
        VStack(alignment: .leading, spacing: Tokens.spacingXS) {
            Text("SETTINGS")
                .kicker()
                .foregroundStyle(.sage)

            Text("Vocabulary List")
                .font(.biscottiSerif(27))
                .tracking(-0.27)
                .foregroundStyle(.ink)

            Text("Words to watch for in every meeting.")
                .font(.system(size: 13))
                .foregroundStyle(.inkSecondary)
        }
    }

    // MARK: - Add term

    private var addTermField: some View {
        HStack(spacing: Tokens.spacingSM) {
            TextField("Add a word or phrase\u{2026}", text: $newTerm)
                .textFieldStyle(.roundedBorder)
                .focused($addFieldFocused)
                .onSubmit { addTerm() }
                .onChange(of: newTerm) {
                    validationError = nil
                }

            Button("Add") { addTerm() }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .disabled(newTerm.trimmingCharacters(in: .whitespaces).isEmpty)
        }
    }

    @ViewBuilder
    private var validationMessage: some View {
        if let error = validationError {
            Text(validationMessageText(error))
                .font(Tokens.metadataFont)
                .foregroundStyle(.signalRedText)
        }
    }

    private func validationMessageText(
        _ error: VocabularyTermError
    ) -> String {
        switch error {
        case let .duplicate(existing):
            "\u{201C}\(existing)\u{201D} is already in your list."
        case .tooLong:
            "Keep terms under 60 characters."
        }
    }

    private func addTerm() {
        Task {
            let result = await viewModel.addVocabularyTerm(newTerm)
            validationError = result
            if result == nil {
                newTerm = ""
            }
        }
    }

    // MARK: - Term list

    @ViewBuilder
    private var termList: some View {
        if viewModel.vocabularyTerms.isEmpty {
            emptyState
        } else {
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(
                        Array(viewModel.vocabularyTerms.enumerated()),
                        id: \.offset
                    ) { index, term in
                        termRow(index: index, term: term)
                        if index < viewModel.vocabularyTerms.count - 1 {
                            Divider()
                        }
                    }
                }
            }
            .frame(maxHeight: 320)
        }
    }

    private func termRow(index: Int, term: String) -> some View {
        HStack {
            if editingIndex == index {
                TextField("", text: $editingText)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit { commitEdit(at: index) }
            } else {
                Text(term)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
                    .onTapGesture { beginEdit(at: index, term: term) }
            }

            Button {
                Task { await viewModel.removeVocabularyTerm(at: index) }
            } label: {
                Image(systemName: "minus.circle.fill")
                    .foregroundStyle(.signalRedText)
            }
            .buttonStyle(.plain)
        }
        .padding(.vertical, 6)
        .padding(.horizontal, Tokens.spacingSM)
    }

    private var emptyState: some View {
        Text(
            "No words yet. Add names, company names, or technical terms Biscotti should listen for."
        )
        .font(Tokens.metadataFont)
        .foregroundStyle(Tokens.secondaryText)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, Tokens.spacingMD)
    }

    // MARK: - Inline editing

    private func beginEdit(at index: Int, term: String) {
        editingIndex = index
        editingText = term
    }

    private func commitEdit(at index: Int) {
        let trimmed = editingText.trimmingCharacters(in: .whitespaces)
        if trimmed.isEmpty || trimmed == viewModel.vocabularyTerms[index] {
            editingIndex = nil
            return
        }
        Task {
            let result = await viewModel.updateVocabularyTerm(
                at: index, to: editingText
            )
            if result == nil {
                editingIndex = nil
            }
            // On validation error the field stays open so the user
            // can correct. No inline message for edits -- the revert
            // is the feedback.
        }
    }

    // MARK: - Footer

    private var footerSection: some View {
        HStack {
            Spacer()
            Button("Done") {
                // Commit any in-progress edit before closing
                if let index = editingIndex {
                    commitEdit(at: index)
                }
                dismiss()
            }
            .keyboardShortcut(.defaultAction)
        }
    }
}
