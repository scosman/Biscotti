import AppKit
import DesignSystem
import MarkdownEngine

// MARK: - Biscotti configuration factory

public extension MarkdownEditorConfiguration {
    /// Builds a `MarkdownEditorConfiguration` themed to the F Sage identity.
    ///
    /// Maps Biscotti design tokens onto the engine's knobs:
    /// - Ink body text, sage links, dimmed-ink markers always visible.
    /// - Prose-friendly defaults (auto-close pairs off, list helpers on).
    /// - Reduced overscroll for a bounded inline editor box.
    /// - No wiki-link, image-embed, syntax-highlight, or LaTeX services.
    ///
    /// - Parameter baseFontSize: The body font size (in points) the editor
    ///   will use. Marker font size is set equal to this value so syntax
    ///   markers remain visible at all times rather than shrinking.
    static func biscotti(baseFontSize: CGFloat) -> MarkdownEditorConfiguration {
        let theme = MarkdownEditorTheme(
            bodyText: .ink,
            mutedText: .inkSecondary,
            disabledText: .inkTertiary,
            headingMarker: .inkSecondary,
            link: .sage,
            incompleteLink: .sage,
            findMatchHighlight: .accentWashStrong,
            findCurrentMatchHighlight: .findHighlightFocused,
            strikethroughColor: .inkSecondary
        )

        return MarkdownEditorConfiguration(
            theme: theme,
            markers: MarkerStyle(hiddenMarkerFontSize: baseFontSize),
            lists: ListStyle(helpersEnabled: true, autoClosePairsEnabled: false),
            overscroll: OverscrollPolicy(percent: 0, maxPoints: 8, minPoints: 4),
            textInsets: TextInsets(horizontal: 8, vertical: 8),
            readingWidth: nil
        )
    }
}

// MARK: - Placeholder helper

/// Builds the styled placeholder `NSAttributedString` shown while the
/// editor is empty. Uses dimmed ink at the given font.
func makePlaceholder(_ text: String, fontName: String, fontSize: CGFloat) -> NSAttributedString {
    let font = NSFont(name: fontName, size: fontSize) ?? NSFont.systemFont(ofSize: fontSize)
    return NSAttributedString(
        string: text,
        attributes: [
            .foregroundColor: NSColor.inkSecondary,
            .font: font
        ]
    )
}
