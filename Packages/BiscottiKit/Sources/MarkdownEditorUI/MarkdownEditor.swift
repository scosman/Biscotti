import DesignSystem
import MarkdownEngine
import SwiftUI

/// A Biscotti-themed live markdown editor.
///
/// Wraps the third-party `NativeTextViewWrapper` from `MarkdownEngine`
/// with the F Sage color palette, dimmed markers (hide-on-blur), and
/// prose-friendly defaults. Uses `.fitsContent` height behavior so the
/// editor grows to fit its content instead of scrolling internally --
/// the enclosing page scroll view handles overflow.
///
/// Callers interact with a plain markdown `String` binding and never
/// see the engine's configuration object.
///
/// ```swift
/// ScrollView {
///     MarkdownEditor(
///         text: $notes,
///         documentId: meeting.id.uuidString,
///         placeholder: "Add notes..."
///     )
///     .frame(minHeight: 120)
/// }
/// ```
public struct MarkdownEditor: View {
    @Binding private var text: String
    private let documentId: String
    private let placeholder: String
    private let isEditable: Bool

    /// - Parameters:
    ///   - text: Two-way binding to the raw markdown source string.
    ///   - documentId: Stable per-document identity for undo / editor state.
    ///   - placeholder: Ghost text shown while the editor is empty.
    ///   - isEditable: Pass `false` for a live-rendered, read-only view.
    public init(
        text: Binding<String>,
        documentId: String,
        placeholder: String = "",
        isEditable: Bool = true
    ) {
        _text = text
        self.documentId = documentId
        self.placeholder = placeholder
        self.isEditable = isEditable
    }

    public var body: some View {
        NativeTextViewWrapper(
            text: $text,
            configuration: .biscotti(),
            fontName: Self.bodyFontName,
            fontSize: Self.bodyFontSize,
            documentId: documentId,
            isEditable: isEditable,
            placeholder: makePlaceholder(placeholder, fontName: Self.bodyFontName, fontSize: Self.bodyFontSize)
        )
    }

    // MARK: - Font constants

    // These are static constants rather than Dynamic-Type-responsive
    // values. The engine's NSTextView doesn't participate in the SwiftUI
    // Dynamic Type pipeline, so a fixed size is appropriate for now.
    // If the app later adopts user-adjustable text sizing, promote these
    // to parameters or derive them from DesignSystem tokens.

    /// The system body font name used by the editor. Derived from
    /// `NSFont.systemFont` so it resolves on every Mac.
    static let bodyFontName: String = NSFont.systemFont(ofSize: NSFont.systemFontSize).fontName

    /// Notes body font size. Tuned to match the app's body text.
    static let bodyFontSize: CGFloat = 14
}

// MARK: - Preview

#Preview("Markdown Editor") {
    struct PreviewHost: View {
        @State private var text = """
        ## Agenda
        Ship *Q3* plan

        - [ ] follow up with Sam
        - [x] send recap

        > Key insight from the meeting

        Normal paragraph with **bold** and ~~strikethrough~~.
        """

        var body: some View {
            ScrollView {
                MarkdownEditor(
                    text: $text,
                    documentId: "preview",
                    placeholder: "Add notes..."
                )
                .frame(minHeight: 120)
                .padding()
            }
            .background(Color.paper)
        }
    }
    return PreviewHost()
}
