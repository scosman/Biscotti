import AppKit
import DesignSystem
import MarkdownEngine

// MARK: - Biscotti configuration factory

public extension MarkdownEditorConfiguration {
    /// Builds a `MarkdownEditorConfiguration` themed to the F Sage identity.
    ///
    /// Maps Biscotti design tokens onto the engine's knobs:
    /// - Ink body text, sage links, dimmed-ink markers.
    /// - Markers use the engine's default hide-on-blur behavior: visible
    ///   and dimmed while the caret is on the line, hidden when the caret
    ///   leaves. (Always-visible markers are not achievable via config --
    ///   the engine's `shrinkInactiveMarkers` applies both a tiny font
    ///   AND a negative kern to collapse layout advance, so setting
    ///   `hiddenMarkerFontSize` to body size causes text overlap.)
    /// - Prose-friendly defaults (auto-close pairs off, list helpers on).
    /// - Reduced overscroll for a bounded inline editor box.
    /// - No wiki-link, image-embed, syntax-highlight, or LaTeX services.
    ///
    static func biscotti() -> MarkdownEditorConfiguration {
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

        // Markers use the engine default `hiddenMarkerFontSize` (0.1pt).
        // The engine's shrink mechanism applies both a tiny font AND a
        // negative kern equal to the font size, collapsing layout width.
        // Setting hiddenMarkerFontSize = baseFontSize draws the glyph at
        // full size but the -14pt kern shifts following text left, causing
        // overlap. The default 0.1pt keeps hide/reveal correct.
        return MarkdownEditorConfiguration(
            theme: theme,
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
