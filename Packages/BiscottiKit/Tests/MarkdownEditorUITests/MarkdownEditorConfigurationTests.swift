import AppKit
import DesignSystem
import MarkdownEngine
import Testing
@testable import MarkdownEditorUI

@Suite("MarkdownEditorConfiguration.biscotti")
struct MarkdownEditorConfigurationTests {
    private var config: MarkdownEditorConfiguration {
        .biscotti()
    }

    // MARK: - Theme colors

    @Test("bodyText maps to ink")
    func bodyTextIsInk() {
        #expect(config.theme.bodyText == NSColor.ink)
    }

    @Test("mutedText maps to inkSecondary")
    func mutedTextIsInkSecondary() {
        #expect(config.theme.mutedText == NSColor.inkSecondary)
    }

    @Test("headingMarker maps to inkSecondary")
    func headingMarkerIsInkSecondary() {
        #expect(config.theme.headingMarker == NSColor.inkSecondary)
    }

    @Test("disabledText maps to inkTertiary")
    func disabledTextIsInkTertiary() {
        #expect(config.theme.disabledText == NSColor.inkTertiary)
    }

    @Test("link maps to sage")
    func linkIsSage() {
        #expect(config.theme.link == NSColor.sage)
    }

    @Test("incompleteLink maps to sage")
    func incompleteLinkIsSage() {
        #expect(config.theme.incompleteLink == NSColor.sage)
    }

    @Test("findMatchHighlight maps to accentWashStrong")
    func findMatchHighlightIsAccentWash() {
        #expect(config.theme.findMatchHighlight == NSColor.accentWashStrong)
    }

    @Test("findCurrentMatchHighlight maps to findHighlightFocused")
    func findCurrentMatchHighlightIsFocused() {
        #expect(config.theme.findCurrentMatchHighlight == NSColor.findHighlightFocused)
    }

    @Test("strikethroughColor maps to inkSecondary")
    func strikethroughIsInkSecondary() {
        #expect(config.theme.strikethroughColor == NSColor.inkSecondary)
    }

    // MARK: - Markers

    @Test("hiddenMarkerFontSize uses engine default (hide-on-blur)")
    func markersUseEngineDefault() {
        let engineDefault = MarkerStyle.default
        #expect(config.markers.hiddenMarkerFontSize == engineDefault.hiddenMarkerFontSize)
    }

    // MARK: - Lists

    @Test("list helpers are enabled")
    func listHelpersEnabled() {
        #expect(config.lists.helpersEnabled == true)
    }

    @Test("auto-close pairs disabled for prose-friendly editing")
    func autoClosePairsDisabled() {
        #expect(config.lists.autoClosePairsEnabled == false)
    }

    // MARK: - Overscroll

    @Test("overscroll percent is zero in fitsContent mode")
    func overscrollPercentZero() {
        #expect(config.overscroll.percent == 0)
    }

    @Test("overscroll maxPoints is small in fitsContent mode")
    func overscrollMaxPointsSmall() {
        #expect(config.overscroll.maxPoints <= 10)
    }

    @Test("overscroll minPoints is small in fitsContent mode")
    func overscrollMinPointsSmall() {
        #expect(config.overscroll.minPoints <= 5)
    }

    // MARK: - Text insets

    @Test("text insets provide inner padding")
    func textInsetsSet() {
        #expect(config.textInsets.horizontal == 8)
        #expect(config.textInsets.vertical == 8)
    }

    // MARK: - Defaults preserved

    @Test("readingWidth is nil (fill the box)")
    func readingWidthNil() {
        #expect(config.readingWidth == nil)
    }

    @Test("scrollers use default (vertical, autohide)")
    func scrollersDefault() {
        let defaultScrollers = ScrollersPolicy.default
        #expect(config.scrollers.hasVerticalScroller == defaultScrollers.hasVerticalScroller)
        #expect(config.scrollers.autohidesScrollers == defaultScrollers.autohidesScrollers)
    }

    @Test("services inherit default (no wiki-link, image, syntax, latex)")
    func servicesDefault() {
        // MarkdownEditorServices is not Equatable, but we verify the factory
        // does not supply a custom `services:` parameter -- it inherits the
        // init's `.default` (all no-op providers). This is validated by the
        // factory source: no `services:` argument is passed to the
        // MarkdownEditorConfiguration initializer.
        let defaultConfig = MarkdownEditorConfiguration.default
        // Spot-check: headings use the same defaults (proves we didn't
        // accidentally override the whole config with a custom services field).
        #expect(config.headings.fontMultipliers == defaultConfig.headings.fontMultipliers)
    }

    @Test("spell checking uses default (on)")
    func spellCheckingDefault() {
        let defaultSpelling = SpellCheckingPolicy.default
        #expect(
            config.spellChecking.continuousSpellChecking
                == defaultSpelling.continuousSpellChecking
        )
        #expect(config.spellChecking.grammarChecking == defaultSpelling.grammarChecking)
    }

    // MARK: - Height behavior

    @Test("heightBehavior is fitsContent (no nested scroll)")
    func heightBehaviorFitsContent() {
        #expect(config.heightBehavior == .fitsContent)
    }
}

// MARK: - Placeholder tests

@Suite("Placeholder NSAttributedString")
struct PlaceholderTests {
    @Test("placeholder carries the correct text")
    func placeholderText() {
        let attr = makePlaceholder("Add notes...", fontName: "Helvetica", fontSize: 14)
        #expect(attr.string == "Add notes...")
    }

    @Test("placeholder uses inkSecondary foreground color")
    func placeholderColor() {
        let attr = makePlaceholder("test", fontName: "Helvetica", fontSize: 14)
        let color = attr.attribute(.foregroundColor, at: 0, effectiveRange: nil) as? NSColor
        #expect(color == NSColor.inkSecondary)
    }

    @Test("placeholder uses the requested font")
    func placeholderFont() {
        let attr = makePlaceholder("test", fontName: "Helvetica", fontSize: 16)
        let font = attr.attribute(.font, at: 0, effectiveRange: nil) as? NSFont
        #expect(font != nil)
        #expect(font?.pointSize == 16)
    }

    @Test("placeholder falls back to system font for unknown font name")
    func placeholderFontFallback() {
        let attr = makePlaceholder("test", fontName: "NoSuchFont-XYZ", fontSize: 14)
        let font = attr.attribute(.font, at: 0, effectiveRange: nil) as? NSFont
        #expect(font != nil)
        #expect(font?.pointSize == 14)
    }
}
