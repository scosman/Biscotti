import Foundation
import Testing
@testable import SummaryPromptUI

@Suite("SummaryPromptModel")
struct SummaryPromptModelTests {
    private static let defaultPrompt = "Produce a clear summary of the meeting."

    // MARK: - isEmpty

    @Test("isEmpty: whitespace-only text is empty")
    @MainActor func isEmptyWhitespaceOnly() {
        let model = SummaryPromptModel(
            workingText: "   \n\t  ",
            initialText: Self.defaultPrompt,
            defaultText: Self.defaultPrompt,
            mode: .global
        )
        #expect(model.isEmpty)
    }

    @Test("isEmpty: empty string is empty")
    @MainActor func isEmptyEmptyString() {
        let model = SummaryPromptModel(
            workingText: "",
            initialText: Self.defaultPrompt,
            defaultText: Self.defaultPrompt,
            mode: .global
        )
        #expect(model.isEmpty)
    }

    @Test("isEmpty: non-empty text is not empty")
    @MainActor func isEmptyNonEmpty() {
        let model = SummaryPromptModel(
            workingText: "Write a summary.",
            initialText: Self.defaultPrompt,
            defaultText: Self.defaultPrompt,
            mode: .global
        )
        #expect(!model.isEmpty)
    }

    // MARK: - hasUnsavedChanges

    @Test("hasUnsavedChanges: modified text reports true")
    @MainActor func hasUnsavedChangesModified() {
        let model = SummaryPromptModel(
            workingText: "Modified prompt",
            initialText: Self.defaultPrompt,
            defaultText: Self.defaultPrompt,
            mode: .global
        )
        #expect(model.hasUnsavedChanges)
    }

    @Test("hasUnsavedChanges: unmodified text reports false")
    @MainActor func hasUnsavedChangesUnmodified() {
        let model = SummaryPromptModel(
            workingText: Self.defaultPrompt,
            initialText: Self.defaultPrompt,
            defaultText: Self.defaultPrompt,
            mode: .global
        )
        #expect(!model.hasUnsavedChanges)
    }

    @Test("hasUnsavedChanges: mutation triggers true")
    @MainActor func hasUnsavedChangesMutation() {
        let model = SummaryPromptModel(
            workingText: Self.defaultPrompt,
            initialText: Self.defaultPrompt,
            defaultText: Self.defaultPrompt,
            mode: .global
        )
        #expect(!model.hasUnsavedChanges)
        model.workingText += " Extra."
        #expect(model.hasUnsavedChanges)
    }

    // MARK: - isDefault

    @Test("isDefault: matches default with trailing whitespace")
    @MainActor func isDefaultMatchesTrimmed() {
        let model = SummaryPromptModel(
            workingText: Self.defaultPrompt + "  \n",
            initialText: Self.defaultPrompt,
            defaultText: Self.defaultPrompt,
            mode: .global
        )
        #expect(model.isDefault)
    }

    @Test("isDefault: exact match")
    @MainActor func isDefaultExact() {
        let model = SummaryPromptModel(
            workingText: Self.defaultPrompt,
            initialText: Self.defaultPrompt,
            defaultText: Self.defaultPrompt,
            mode: .global
        )
        #expect(model.isDefault)
    }

    @Test("isDefault: different text is not default")
    @MainActor func isDefaultDifferent() {
        let model = SummaryPromptModel(
            workingText: "Custom prompt",
            initialText: Self.defaultPrompt,
            defaultText: Self.defaultPrompt,
            mode: .global
        )
        #expect(!model.isDefault)
    }

    // MARK: - added / append

    @Test("added: block present returns true")
    @MainActor func addedBlockPresent() {
        let example = PromptExample.builtIn[0] // Slack recap
        let model = SummaryPromptModel(
            workingText: Self.defaultPrompt + "\n\n" + example.block,
            initialText: Self.defaultPrompt,
            defaultText: Self.defaultPrompt,
            mode: .global
        )
        #expect(model.added(example))
    }

    @Test("added: block absent returns false")
    @MainActor func addedBlockAbsent() {
        let example = PromptExample.builtIn[0]
        let model = SummaryPromptModel(
            workingText: Self.defaultPrompt,
            initialText: Self.defaultPrompt,
            defaultText: Self.defaultPrompt,
            mode: .global
        )
        #expect(!model.added(example))
    }

    @Test("append: adds block with separator")
    @MainActor func appendAddsBlock() {
        let example = PromptExample.builtIn[0]
        let model = SummaryPromptModel(
            workingText: Self.defaultPrompt,
            initialText: Self.defaultPrompt,
            defaultText: Self.defaultPrompt,
            mode: .global
        )
        model.append(example)
        #expect(model.workingText == Self.defaultPrompt + "\n\n" + example.block)
        #expect(model.added(example))
    }

    @Test("append: no duplicate append")
    @MainActor func appendNoDuplicate() {
        let example = PromptExample.builtIn[0]
        let model = SummaryPromptModel(
            workingText: Self.defaultPrompt,
            initialText: Self.defaultPrompt,
            defaultText: Self.defaultPrompt,
            mode: .global
        )
        model.append(example)
        let afterFirst = model.workingText
        model.append(example)
        #expect(model.workingText == afterFirst)
    }

    @Test("append: to empty text places block without leading separator")
    @MainActor func appendToEmpty() {
        let example = PromptExample.builtIn[0]
        let model = SummaryPromptModel(
            workingText: "",
            initialText: Self.defaultPrompt,
            defaultText: Self.defaultPrompt,
            mode: .global
        )
        model.append(example)
        #expect(model.workingText == example.block)
    }

    @Test("append: to whitespace-only text replaces with block")
    @MainActor func appendToWhitespaceOnly() {
        let example = PromptExample.builtIn[0]
        let model = SummaryPromptModel(
            workingText: "  \n\t ",
            initialText: Self.defaultPrompt,
            defaultText: Self.defaultPrompt,
            mode: .global
        )
        model.append(example)
        #expect(model.workingText == example.block)
    }

    @Test("append: multiple examples accumulate")
    @MainActor func appendMultiple() {
        let first = PromptExample.builtIn[0]
        let second = PromptExample.builtIn[1]
        let model = SummaryPromptModel(
            workingText: Self.defaultPrompt,
            initialText: Self.defaultPrompt,
            defaultText: Self.defaultPrompt,
            mode: .global
        )
        model.append(first)
        model.append(second)
        #expect(model.added(first))
        #expect(model.added(second))
        let expected = Self.defaultPrompt + "\n\n" + first.block + "\n\n" + second.block
        #expect(model.workingText == expected)
    }

    // MARK: - restoreDefault

    @Test("restoreDefault: sets workingText to defaultText")
    @MainActor func restoreDefault() {
        let model = SummaryPromptModel(
            workingText: "Custom prompt that I changed",
            initialText: Self.defaultPrompt,
            defaultText: Self.defaultPrompt,
            mode: .global
        )
        model.restoreDefault()
        #expect(model.workingText == Self.defaultPrompt)
        #expect(model.isDefault)
    }

    // MARK: - alsoSaveAsDefault

    @Test("alsoSaveAsDefault: defaults to false")
    @MainActor func alsoSaveAsDefaultDefaultsFalse() {
        let ref = MeetingReference(title: "Test", date: Date())
        let model = SummaryPromptModel(
            workingText: Self.defaultPrompt,
            initialText: Self.defaultPrompt,
            defaultText: Self.defaultPrompt,
            mode: .perMeeting(reference: ref, summaryWasEdited: false)
        )
        #expect(!model.alsoSaveAsDefault)
    }
}
