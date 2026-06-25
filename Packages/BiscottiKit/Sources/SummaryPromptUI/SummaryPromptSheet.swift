import DesignSystem
import MarkdownEditorUI
import SwiftUI

/// The summary prompt editor sheet, used in both Global (Settings) and
/// Per-meeting (Regenerate) modes.
///
/// Callback-driven: the sheet never imports AppCore, DataStore, or
/// Intelligence. All persistence and generation logic lives in the host
/// view-model.
public struct SummaryPromptSheet: View {
    @Bindable private var model: SummaryPromptModel
    private let onSave: (String) -> Void
    private let onRegenerate: (_ text: String, _ alsoSave: Bool) -> Void
    private let onCancel: () -> Void

    @State private var showRestoreConfirm = false
    @State private var showDiscardConfirm = false

    /// - Parameters:
    ///   - model: The observable model holding working text and mode.
    ///   - onSave: Called when the user taps Save (Global mode).
    ///   - onRegenerate: Called when the user taps Regenerate (Per-meeting mode).
    ///   - onCancel: Called when the user cancels (after any unsaved-changes confirmation).
    public init(
        model: SummaryPromptModel,
        onSave: @escaping (String) -> Void,
        onRegenerate: @escaping (_ text: String, _ alsoSave: Bool) -> Void,
        onCancel: @escaping () -> Void
    ) {
        self.model = model
        self.onSave = onSave
        self.onRegenerate = onRegenerate
        self.onCancel = onCancel
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: Tokens.spacingMD) {
            headerSection
            promptLabel
            editorCard
            emptyCaption
            exampleLabel
            exampleChips
            perMeetingControls
            Divider()
            footerSection
        }
        .padding(Tokens.spacingLG)
        .frame(width: 720)
        .confirmationDialog(
            "Restore the default summary prompt?",
            isPresented: $showRestoreConfirm,
            titleVisibility: .visible
        ) {
            Button("Restore", role: .destructive) {
                model.restoreDefault()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Your current edits in this editor will be replaced.")
        }
        .confirmationDialog(
            "Discard your changes?",
            isPresented: $showDiscardConfirm,
            titleVisibility: .visible
        ) {
            Button("Discard", role: .destructive) {
                onCancel()
            }
            Button("Keep Editing", role: .cancel) {}
        }
    }

    // MARK: - Header

    private var headerSection: some View {
        VStack(alignment: .leading, spacing: Tokens.spacingXS) {
            Text(kickerText)
                .kicker()
                .foregroundStyle(.sage)

            Text(titleText)
                .font(.biscottiSerif(27))
                .tracking(-0.27)
                .foregroundStyle(.ink)

            Text(subtitleText)
                .font(Tokens.metadataFont)
                .foregroundStyle(.inkSecondary)
                .frame(maxWidth: 560, alignment: .leading)

            if case let .perMeeting(reference, _) = model.mode {
                MeetingReferenceChip(reference: reference)
                    .padding(.top, Tokens.spacingXS)
            }
        }
    }

    private var kickerText: String {
        switch model.mode {
        case .global: "MEETING SUMMARY"
        case .perMeeting: "RE-SUMMARIZE"
        }
    }

    private var titleText: String {
        switch model.mode {
        case .global: "Summary Prompt"
        case .perMeeting: "Re-summarize this meeting"
        }
    }

    private var subtitleText: String {
        switch model.mode {
        case .global:
            "These are the instructions Biscotti sends the on-device model to write each meeting summary. Edit them directly. Changes apply to every future summary."
        case .perMeeting:
            "Customize the prompt for this meeting\u{2019}s summary, then regenerate. Your saved prompt stays as it is unless you choose to save these changes."
        }
    }

    // MARK: - Prompt editor

    private var promptLabel: some View {
        Text("PROMPT")
            .kicker()
            .foregroundStyle(.inkTertiary)
    }

    private var editorCard: some View {
        MarkdownPromptField(
            text: $model.workingText,
            documentId: editorDocumentId
        )
        .frame(height: 340)
        .background(Color.elevatedFill)
        .clipShape(RoundedRectangle(cornerRadius: Tokens.cardRadius))
        .overlay(
            RoundedRectangle(cornerRadius: Tokens.cardRadius)
                .stroke(Color.cardStroke, lineWidth: 0.5)
        )
    }

    /// The engine uses documentId as an in-memory key for undo state and
    /// scroll-offset restoration when a single NativeTextViewWrapper is
    /// reused across documents. Only one sheet is ever open at a time, so
    /// a fixed per-mode string is sufficient — no title/UUID needed.
    private var editorDocumentId: String {
        switch model.mode {
        case .global:
            "summary-prompt-global"
        case .perMeeting:
            "summary-prompt-meeting"
        }
    }

    // MARK: - Empty caption

    @ViewBuilder
    private var emptyCaption: some View {
        if model.isEmpty {
            Text("The prompt can\u{2019}t be empty.")
                .font(Tokens.metadataFont)
                .foregroundStyle(.signalRedText)
        }
    }

    // MARK: - Example chips

    private var exampleLabel: some View {
        Text("ADD EXAMPLE")
            .kicker()
            .foregroundStyle(.inkTertiary)
    }

    private var exampleChips: some View {
        FlowLayout(horizontalSpacing: 6, verticalSpacing: 6) {
            ForEach(PromptExample.builtIn) { example in
                exampleChip(example)
            }
        }
    }

    private func exampleChip(_ example: PromptExample) -> some View {
        let isAdded = model.added(example)

        return Button {
            model.append(example)
        } label: {
            HStack(spacing: 4) {
                Image(systemName: isAdded ? "checkmark" : "plus")
                    .font(.system(size: 11, weight: .medium))

                Text(example.name)
                    .font(.system(size: 11.5, weight: .medium))
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(
                RoundedRectangle(cornerRadius: Tokens.chipRadius)
                    .fill(isAdded ? Color.accentWashStrong : Color.neutralChip)
            )
            .foregroundStyle(isAdded ? .sage : .ink)
        }
        .buttonStyle(.plain)
        .disabled(isAdded)
    }

    // MARK: - Per-meeting controls

    @ViewBuilder
    private var perMeetingControls: some View {
        if case let .perMeeting(_, summaryWasEdited) = model.mode {
            VStack(alignment: .leading, spacing: Tokens.spacingSM) {
                Toggle("Also save these changes as my default", isOn: $model.alsoSaveAsDefault)

                if summaryWasEdited {
                    Text("Regenerating will replace the summary you edited for this meeting.")
                        .font(Tokens.metadataFont)
                        .foregroundStyle(.inkSecondary)
                }
            }
        }
    }

    // MARK: - Footer

    private var footerSection: some View {
        HStack {
            Button {
                showRestoreConfirm = true
            } label: {
                Label("Restore Default", systemImage: "arrow.counterclockwise")
            }
            .buttonStyle(.borderless)
            .foregroundStyle(.inkSecondary)
            .disabled(model.isDefault)

            Spacer()

            Button("Cancel") {
                attemptCancel()
            }
            .keyboardShortcut(.cancelAction)

            primaryButton
        }
    }

    @ViewBuilder
    private var primaryButton: some View {
        switch model.mode {
        case .global:
            Button("Save") {
                onSave(model.workingText)
            }
            .buttonStyle(.borderedProminent)
            .tint(.sage)
            .keyboardShortcut(.defaultAction)
            .disabled(model.isEmpty)

        case .perMeeting:
            Button("Regenerate") {
                onRegenerate(model.workingText, model.alsoSaveAsDefault)
            }
            .buttonStyle(.borderedProminent)
            .tint(.sage)
            .keyboardShortcut(.defaultAction)
            .disabled(model.isEmpty)
        }
    }

    // MARK: - Cancel logic

    private func attemptCancel() {
        if model.hasUnsavedChanges {
            showDiscardConfirm = true
        } else {
            onCancel()
        }
    }
}

// MARK: - Previews

#if DEBUG
    #Preview("Global Mode") {
        let model = SummaryPromptModel(
            workingText: """
            Produce a clear, well-organized markdown summary of the meeting \
            covering the key decisions, discussion topics, and outcomes. At the end, \
            include a "## Action Items" section as a checklist using `- [ ]` format, \
            with owners noted when clear from the transcript.
            """,
            initialText: """
            Produce a clear, well-organized markdown summary of the meeting \
            covering the key decisions, discussion topics, and outcomes. At the end, \
            include a "## Action Items" section as a checklist using `- [ ]` format, \
            with owners noted when clear from the transcript.
            """,
            defaultText: """
            Produce a clear, well-organized markdown summary of the meeting \
            covering the key decisions, discussion topics, and outcomes. At the end, \
            include a "## Action Items" section as a checklist using `- [ ]` format, \
            with owners noted when clear from the transcript.
            """,
            mode: .global
        )

        SummaryPromptSheet(
            model: model,
            onSave: { _ in },
            onRegenerate: { _, _ in },
            onCancel: {}
        )
        .background(Color.paper)
    }

    #Preview("Per-Meeting Mode") {
        let reference = MeetingReference(
            title: "Q3 Planning Sync",
            date: Date(),
            duration: 2700
        )
        let model = SummaryPromptModel(
            workingText: """
            Produce a clear, well-organized markdown summary of the meeting \
            covering the key decisions, discussion topics, and outcomes.
            """,
            initialText: """
            Produce a clear, well-organized markdown summary of the meeting \
            covering the key decisions, discussion topics, and outcomes.
            """,
            defaultText: """
            Produce a clear, well-organized markdown summary of the meeting \
            covering the key decisions, discussion topics, and outcomes.
            """,
            mode: .perMeeting(reference: reference, summaryWasEdited: true)
        )

        SummaryPromptSheet(
            model: model,
            onSave: { _ in },
            onRegenerate: { _, _ in },
            onCancel: {}
        )
        .background(Color.paper)
    }
#endif
