import Foundation

/// Observable model backing the `SummaryPromptSheet`.
///
/// Holds the working editor text and provides pure helpers for the sheet's
/// UI state (empty, unsaved changes, is-default, example detection). The
/// model is callback-driven and never imports persistence or generation
/// modules.
@MainActor @Observable
public final class SummaryPromptModel: Identifiable {
    public let id = UUID()

    // MARK: - State

    /// The text currently in the editor (two-way bound to the field).
    public var workingText: String

    /// The text the editor was opened with — used for unsaved-changes detection.
    public let initialText: String

    /// The factory default prompt — used for Restore Default and is-default comparison.
    public let defaultText: String

    /// Which mode the sheet is presented in.
    public let mode: SummaryPromptMode

    /// Per-meeting only: whether to also persist the prompt as the new global default.
    public var alsoSaveAsDefault: Bool

    // MARK: - Init

    public init(
        workingText: String,
        initialText: String,
        defaultText: String,
        mode: SummaryPromptMode,
        alsoSaveAsDefault: Bool = false
    ) {
        self.workingText = workingText
        self.initialText = initialText
        self.defaultText = defaultText
        self.mode = mode
        self.alsoSaveAsDefault = alsoSaveAsDefault
    }

    // MARK: - Pure helpers

    /// Whether the working text is empty or whitespace-only.
    public var isEmpty: Bool {
        workingText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// Whether the editor has been modified since opening.
    public var hasUnsavedChanges: Bool {
        workingText != initialText
    }

    /// Whether the working text matches the factory default (trimmed comparison).
    public var isDefault: Bool {
        workingText.trimmingCharacters(in: .whitespacesAndNewlines)
            == defaultText.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Whether the given example's block is already present verbatim in the
    /// working text.
    public func added(_ example: PromptExample) -> Bool {
        workingText.contains(example.block)
    }

    /// Appends the example's block to the end of the working text, separated
    /// by a blank line. No-op if the block is already present.
    public func append(_ example: PromptExample) {
        guard !added(example) else { return }

        if workingText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            workingText = example.block
        } else {
            workingText += "\n\n" + example.block
        }
    }

    /// Replaces the working text with the factory default.
    public func restoreDefault() {
        workingText = defaultText
    }
}
