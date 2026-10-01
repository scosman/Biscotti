import DesignSystem
import SwiftUI

// MARK: - Custom Vocabulary section

extension SettingsView {
    var customVocabularySection: some View {
        Section {
            // Row 1: Master toggle
            VStack(alignment: .leading, spacing: Tokens.spacingXS) {
                Toggle(
                    "Custom Vocabulary",
                    isOn: customVocabularyEnabledBinding
                )
                Text(
                    "Help Biscotti recognize uncommon words you use, like names or technical terms."
                )
                .font(Tokens.metadataFont)
                .foregroundStyle(Tokens.secondaryText)
            }

            // Rows 2 and 3 are hidden (not disabled) when the master toggle is off
            if viewModel.customVocabularyEnabled {
                // Row 2: Vocabulary List
                vocabularyListRow

                // Row 3: Calendar toggle
                VStack(alignment: .leading, spacing: Tokens.spacingXS) {
                    Toggle(
                        "Add Words from Calendar Events",
                        isOn: calendarVocabularyEnabledBinding
                    )
                    Text(
                        "Pull uncommon words from the event\u{2019}s title, description, and attendee names. English only."
                    )
                    .font(Tokens.metadataFont)
                    .foregroundStyle(Tokens.secondaryText)
                }
            }
        } header: {
            HStack {
                Text(Self.sectionTitles[4])
                Spacer()
                Text(Self.customVocabularyHeaderCaption)
                    .font(Tokens.metadataFont)
                    .foregroundStyle(Tokens.secondaryText)
            }
        }
        .sheet(isPresented: $showVocabularyListSheet) {
            VocabularyListSheet(viewModel: viewModel)
        }
    }

    private var vocabularyListRow: some View {
        HStack {
            VStack(alignment: .leading, spacing: Tokens.spacingXS) {
                Text("Vocabulary List")
                Text("Words to watch for in every meeting.")
                    .font(Tokens.metadataFont)
                    .foregroundStyle(Tokens.secondaryText)
            }

            Spacer()

            Button("Edit List (\(viewModel.vocabularyTerms.count))") {
                showVocabularyListSheet = true
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
        }
    }

    private var customVocabularyEnabledBinding: Binding<Bool> {
        Binding(
            get: { viewModel.customVocabularyEnabled },
            set: { newValue in
                Task { await viewModel.setCustomVocabularyEnabled(newValue) }
            }
        )
    }

    private var calendarVocabularyEnabledBinding: Binding<Bool> {
        Binding(
            get: { viewModel.calendarVocabularyEnabled },
            set: { newValue in
                Task {
                    await viewModel.setCalendarVocabularyEnabled(newValue)
                }
            }
        )
    }
}
