import DesignSystem
import MarkdownEngine
import SwiftUI

/// A bounded, scrolling markdown editor for prompt editing.
///
/// Unlike `MarkdownEditor` (which uses `.fitsContent` and grows with its
/// text), this view uses `.scrolls` height behavior so it remains at a
/// fixed height with internal scrolling — appropriate for sheet-embedded
/// prompt fields.
///
/// The engine's text view background is clear, so callers can wrap this
/// view in their own field chrome (background, border, corner radius).
///
/// ```swift
/// MarkdownPromptField(text: $prompt, documentId: "summary-prompt")
///     .frame(height: 340)
/// ```
public struct MarkdownPromptField: View {
    @Binding private var text: String
    private let documentId: String
    private let monospace: Bool

    /// - Parameters:
    ///   - text: Two-way binding to the raw markdown source string.
    ///   - documentId: Stable per-document identity for undo / editor state.
    ///   - monospace: When `true`, renders in JetBrains Mono instead of the
    ///     system body font. Falls back to system font if the mono font is
    ///     unavailable.
    public init(text: Binding<String>, documentId: String, monospace: Bool = false) {
        _text = text
        self.documentId = documentId
        self.monospace = monospace
    }

    public var body: some View {
        NativeTextViewWrapper(
            text: $text,
            configuration: .biscottiPromptField(),
            fontName: resolvedFontName,
            fontSize: Self.fontSize,
            documentId: documentId,
            isEditable: true
        )
    }

    // MARK: - Font resolution

    private static let fontSize: CGFloat = 14

    private var resolvedFontName: String {
        if monospace {
            return MonoWeight.regular.postScriptName
        }
        return NSFont.systemFont(ofSize: NSFont.systemFontSize).fontName
    }
}

// MARK: - Prompt-field configuration

public extension MarkdownEditorConfiguration {
    /// Biscotti theme configured for a bounded prompt field.
    ///
    /// Same F Sage palette as `.biscotti()` but uses `.scrolls` height
    /// behavior so the editor scrolls internally within a fixed frame,
    /// and shows a vertical scroller.
    static func biscottiPromptField() -> MarkdownEditorConfiguration {
        MarkdownEditorConfiguration(
            theme: .biscotti,
            lists: ListStyle(helpersEnabled: true, autoClosePairsEnabled: false),
            overscroll: OverscrollPolicy(percent: 0, maxPoints: 8, minPoints: 4),
            scrollers: .vertical,
            textInsets: TextInsets(horizontal: 12, vertical: 10),
            readingWidth: nil,
            heightBehavior: .scrolls
        )
    }
}

// MARK: - Preview

#Preview("MarkdownPromptField") {
    struct PreviewHost: View {
        @State private var text = """
        Produce a clear, well-organized markdown summary of the meeting \
        covering the key decisions, discussion topics, and outcomes.

        ## Action Items
        A checklist using `- [ ]` format, with owners noted.
        """

        var body: some View {
            MarkdownPromptField(text: $text, documentId: "preview")
                .frame(height: 340)
                .background(Color.elevatedFill)
                .clipShape(RoundedRectangle(cornerRadius: Tokens.cardRadius))
                .overlay(
                    RoundedRectangle(cornerRadius: Tokens.cardRadius)
                        .stroke(Color.cardStroke, lineWidth: 0.5)
                )
                .padding()
                .background(Color.paper)
        }
    }
    return PreviewHost()
}
