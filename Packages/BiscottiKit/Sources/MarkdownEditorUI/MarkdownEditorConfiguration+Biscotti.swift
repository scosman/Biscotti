import AppKit
import DesignSystem
import MarkdownEngine

// MARK: - Shared Biscotti theme

public extension MarkdownEditorTheme {
    /// The F Sage color palette shared by all Biscotti editor configurations.
    ///
    /// Ink body text, sage links, dimmed-ink markers.
    static let biscotti = MarkdownEditorTheme(
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
}

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
    /// - `.fitsContent` height behavior: the editor grows to fit its
    ///   content instead of scrolling internally, so the enclosing page
    ///   scroll view handles overflow (no nested scroll region).
    /// - Minimal overscroll (effectively zero in fitsContent mode).
    /// - No wiki-link, image-embed, syntax-highlight, or LaTeX services.
    ///
    static func biscotti() -> MarkdownEditorConfiguration {
        // Markers use the engine default `hiddenMarkerFontSize` (0.1pt).
        // The engine's shrink mechanism applies both a tiny font AND a
        // negative kern equal to the font size, collapsing layout width.
        // Setting hiddenMarkerFontSize = baseFontSize draws the glyph at
        // full size but the -14pt kern shifts following text left, causing
        // overlap. The default 0.1pt keeps hide/reveal correct.
        MarkdownEditorConfiguration(
            theme: .biscotti,
            lists: ListStyle(helpersEnabled: true, autoClosePairsEnabled: false),
            overscroll: OverscrollPolicy(percent: 0, maxPoints: 8, minPoints: 4),
            textInsets: TextInsets(horizontal: 8, vertical: 8),
            readingWidth: nil,
            heightBehavior: .fitsContent
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
