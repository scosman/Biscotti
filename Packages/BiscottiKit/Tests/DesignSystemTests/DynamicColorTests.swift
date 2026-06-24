import AppKit
import Foundation
import SwiftUI
import Testing
@testable import DesignSystem

// MARK: - Test helpers

/// Resolved sRGB color components for comparison.
private struct SRGB {
    let red: CGFloat
    let green: CGFloat
    let blue: CGFloat
    let alpha: CGFloat
}

/// Resolves a dynamic `NSColor` under a specific appearance and returns sRGB components.
private func resolve(
    _ color: NSColor, appearance appearanceName: NSAppearance.Name
) -> SRGB {
    var result = SRGB(red: 0, green: 0, blue: 0, alpha: 0)
    // swiftlint:disable:next force_unwrapping
    NSAppearance(named: appearanceName)!.performAsCurrentDrawingAppearance {
        // swiftlint:disable:next force_unwrapping
        let resolved = color.usingColorSpace(.sRGB)!
        result = SRGB(
            red: resolved.redComponent,
            green: resolved.greenComponent,
            blue: resolved.blueComponent,
            alpha: resolved.alphaComponent
        )
    }
    return result
}

/// Resolves a dynamic SwiftUI `Color` (via its NSColor backing) under a specific appearance.
/// **Assumption:** all SwiftUI `Color` tokens in this codebase are backed by `Color(nsColor:)` or
/// `dynamicColor(light:dark:)` (which uses `Color(nsColor:)` internally), so round-tripping
/// through `NSColor(Color)` recovers the underlying dynamic `NSColor` for appearance resolution.
/// If a token were ever built from a raw `Color(red:green:blue:)` initializer, this helper would
/// lose the dynamic provider and always return the light value.
private func resolve(
    _ color: Color, appearance appearanceName: NSAppearance.Name
) -> SRGB {
    let nsColor = NSColor(color)
    return resolve(nsColor, appearance: appearanceName)
}

/// Sub-8-bit tolerance (1/512 ~ 0.00195).
private let tolerance: CGFloat = 1.0 / 512.0

private func assertSRGB(
    _ actual: SRGB,
    expected: SRGB,
    label: String,
    sourceLocation: SourceLocation = #_sourceLocation
) {
    #expect(
        abs(actual.red - expected.red) <= tolerance,
        "\(label) red: expected \(expected.red), got \(actual.red)",
        sourceLocation: sourceLocation
    )
    #expect(
        abs(actual.green - expected.green) <= tolerance,
        "\(label) green: expected \(expected.green), got \(actual.green)",
        sourceLocation: sourceLocation
    )
    #expect(
        abs(actual.blue - expected.blue) <= tolerance,
        "\(label) blue: expected \(expected.blue), got \(actual.blue)",
        sourceLocation: sourceLocation
    )
    #expect(
        abs(actual.alpha - expected.alpha) <= tolerance,
        "\(label) alpha: expected \(expected.alpha), got \(actual.alpha)",
        sourceLocation: sourceLocation
    )
}

// MARK: - Test 1: Light values match legacy literals

@Suite("Light values match legacy literals")
struct LightValuesTests {
    // Surfaces & ink

    @Test("paper light == #FBFAF5")
    func paperLight() {
        let color = resolve(Color.paper, appearance: .aqua)
        assertSRGB(color, expected: SRGB(red: 0.984, green: 0.980, blue: 0.961, alpha: 1), label: "paper")
    }

    @Test("ink light == #1A1813")
    func inkLight() {
        let color = resolve(NSColor.ink, appearance: .aqua)
        assertSRGB(color, expected: SRGB(red: 0.102, green: 0.094, blue: 0.075, alpha: 1), label: "ink")
    }

    @Test("inkSecondary light == ink@54%")
    func inkSecondaryLight() {
        let color = resolve(NSColor.inkSecondary, appearance: .aqua)
        assertSRGB(color, expected: SRGB(red: 0.102, green: 0.094, blue: 0.075, alpha: 0.54), label: "inkSecondary")
    }

    @Test("inkTertiary light == ink@34%")
    func inkTertiaryLight() {
        let color = resolve(NSColor.inkTertiary, appearance: .aqua)
        assertSRGB(color, expected: SRGB(red: 0.102, green: 0.094, blue: 0.075, alpha: 0.34), label: "inkTertiary")
    }

    @Test("hairline light == ink@11%")
    func hairlineLight() {
        let color = resolve(Color.hairline, appearance: .aqua)
        assertSRGB(color, expected: SRGB(red: 0.102, green: 0.094, blue: 0.075, alpha: 0.11), label: "hairline")
    }

    @Test("neutralChip light == ink@6%")
    func neutralChipLight() {
        let color = resolve(Color.neutralChip, appearance: .aqua)
        assertSRGB(color, expected: SRGB(red: 0.102, green: 0.094, blue: 0.075, alpha: 0.06), label: "neutralChip")
    }

    @Test("cardStroke light == warm dark@10%")
    func cardStrokeLight() {
        let color = resolve(NSColor.cardStroke, appearance: .aqua)
        assertSRGB(color, expected: SRGB(red: 0.102, green: 0.086, blue: 0.055, alpha: 0.10), label: "cardStroke")
    }

    @Test("wall light == #E4E1D8")
    func wallLight() {
        let color = resolve(Color.wall, appearance: .aqua)
        assertSRGB(color, expected: SRGB(red: 0.894, green: 0.882, blue: 0.847, alpha: 1), label: "wall")
    }

    @Test("sidebarTint light == rgba(250,249,244,0.82)")
    func sidebarTintLight() {
        let color = resolve(Color.sidebarTint, appearance: .aqua)
        assertSRGB(color, expected: SRGB(red: 0.980, green: 0.976, blue: 0.957, alpha: 0.82), label: "sidebarTint")
    }

    // Sage family

    @Test("sage light == #4E7D5C")
    func sageLight() {
        let color = resolve(NSColor.sage, appearance: .aqua)
        assertSRGB(color, expected: SRGB(red: 0.306, green: 0.490, blue: 0.361, alpha: 1), label: "sage")
    }

    @Test("accentWashSoft light == sage@8%")
    func accentWashSoftLight() {
        let color = resolve(Color.accentWashSoft, appearance: .aqua)
        assertSRGB(color, expected: SRGB(red: 0.306, green: 0.490, blue: 0.361, alpha: 0.08), label: "accentWashSoft")
    }

    @Test("accentWashStrong light == sage@14%")
    func accentWashStrongLight() {
        let color = resolve(NSColor.accentWashStrong, appearance: .aqua)
        assertSRGB(color, expected: SRGB(red: 0.306, green: 0.490, blue: 0.361, alpha: 0.14), label: "accentWashStrong")
    }

    @Test("softSageFill light == sage@12%")
    func softSageFillLight() {
        let color = resolve(Color.softSageFill, appearance: .aqua)
        assertSRGB(color, expected: SRGB(red: 0.306, green: 0.490, blue: 0.361, alpha: 0.12), label: "softSageFill")
    }

    @Test("findHighlightFocused light == sage@35%")
    func findHighlightFocusedLight() {
        let color = resolve(NSColor.findHighlightFocused, appearance: .aqua)
        assertSRGB(color, expected: SRGB(red: 0.306, green: 0.490, blue: 0.361, alpha: 0.35), label: "findHighlightFocused")
    }

    // Alert red

    @Test("signalRed light == #B23320")
    func signalRedLight() {
        let color = resolve(Color.signalRed, appearance: .aqua)
        assertSRGB(color, expected: SRGB(red: 0.698, green: 0.200, blue: 0.125, alpha: 1), label: "signalRed")
    }

    @Test("recordingOutline light == signalRed@32%")
    func recordingOutlineLight() {
        let color = resolve(Color.recordingOutline, appearance: .aqua)
        assertSRGB(color, expected: SRGB(red: 0.698, green: 0.200, blue: 0.125, alpha: 0.32), label: "recordingOutline")
    }

    // Amber

    @Test("warningOchre light == #C6891E")
    func warningOchreLight() {
        let color = resolve(Color.warningOchre, appearance: .aqua)
        assertSRGB(color, expected: SRGB(red: 0.776, green: 0.537, blue: 0.118, alpha: 1), label: "warningOchre")
    }

    @Test("warningChipText light == #C6891E (same as ochre)")
    func warningChipTextLight() {
        let color = resolve(Color.warningChipText, appearance: .aqua)
        assertSRGB(color, expected: SRGB(red: 0.776, green: 0.537, blue: 0.118, alpha: 1), label: "warningChipText")
    }

    // New tokens — light values must equal the literal they replace

    @Test("cardFill light == #FFFFFF")
    func cardFillLight() {
        let color = resolve(Color.cardFill, appearance: .aqua)
        assertSRGB(color, expected: SRGB(red: 1.0, green: 1.0, blue: 1.0, alpha: 1), label: "cardFill")
    }

    @Test("accentFill light == sage (#4E7D5C)")
    func accentFillLight() {
        let color = resolve(Color.accentFill, appearance: .aqua)
        assertSRGB(color, expected: SRGB(red: 0.306, green: 0.490, blue: 0.361, alpha: 1), label: "accentFill")
    }

    @Test("read light == ink@54%")
    func readLight() {
        let color = resolve(Color.read, appearance: .aqua)
        assertSRGB(color, expected: SRGB(red: 0.102, green: 0.094, blue: 0.075, alpha: 0.54), label: "read")
    }

    @Test("elevatedFill light == #FFFFFF")
    func elevatedFillLight() {
        let color = resolve(Color.elevatedFill, appearance: .aqua)
        assertSRGB(color, expected: SRGB(red: 1.0, green: 1.0, blue: 1.0, alpha: 1), label: "elevatedFill")
    }

    @Test("accentTrack light == sage (#4E7D5C)")
    func accentTrackLight() {
        let color = resolve(Color.accentTrack, appearance: .aqua)
        assertSRGB(color, expected: SRGB(red: 0.306, green: 0.490, blue: 0.361, alpha: 1), label: "accentTrack")
    }

    @Test("signalRedText light == #B23320")
    func signalRedTextLight() {
        let color = resolve(Color.signalRedText, appearance: .aqua)
        assertSRGB(color, expected: SRGB(red: 0.698, green: 0.200, blue: 0.125, alpha: 1), label: "signalRedText")
    }

    @Test("cardShadow light == black@5%")
    func cardShadowLight() {
        let color = resolve(Color.cardShadow, appearance: .aqua)
        assertSRGB(color, expected: SRGB(red: 0, green: 0, blue: 0, alpha: 0.05), label: "cardShadow")
    }

    @Test("controlShadow light == black@6%")
    func controlShadowLight() {
        let color = resolve(Color.controlShadow, appearance: .aqua)
        assertSRGB(color, expected: SRGB(red: 0, green: 0, blue: 0, alpha: 0.06), label: "controlShadow")
    }
}

// MARK: - Test 2: Dark values match design spec

@Suite("Dark values match design spec")
struct DarkValuesTests {
    // Surfaces & ink

    @Test("paper dark == #100E09")
    func paperDark() {
        let color = resolve(Color.paper, appearance: .darkAqua)
        assertSRGB(color, expected: SRGB(red: 0.063, green: 0.055, blue: 0.035, alpha: 1), label: "paper dark")
    }

    @Test("ink dark == #F7F2E8")
    func inkDark() {
        let color = resolve(NSColor.ink, appearance: .darkAqua)
        assertSRGB(color, expected: SRGB(red: 0.969, green: 0.949, blue: 0.910, alpha: 1), label: "ink dark")
    }

    @Test("inkSecondary dark == #F7F2E8@58%")
    func inkSecondaryDark() {
        let color = resolve(NSColor.inkSecondary, appearance: .darkAqua)
        assertSRGB(color, expected: SRGB(red: 0.969, green: 0.949, blue: 0.910, alpha: 0.58), label: "inkSecondary dark")
    }

    @Test("inkTertiary dark == #F7F2E8@36%")
    func inkTertiaryDark() {
        let color = resolve(NSColor.inkTertiary, appearance: .darkAqua)
        assertSRGB(color, expected: SRGB(red: 0.969, green: 0.949, blue: 0.910, alpha: 0.36), label: "inkTertiary dark")
    }

    @Test("hairline dark == #F7F2E8@12%")
    func hairlineDark() {
        let color = resolve(Color.hairline, appearance: .darkAqua)
        assertSRGB(color, expected: SRGB(red: 0.969, green: 0.949, blue: 0.910, alpha: 0.12), label: "hairline dark")
    }

    @Test("neutralChip dark == #F7F2E8@7%")
    func neutralChipDark() {
        let color = resolve(Color.neutralChip, appearance: .darkAqua)
        assertSRGB(color, expected: SRGB(red: 0.969, green: 0.949, blue: 0.910, alpha: 0.07), label: "neutralChip dark")
    }

    @Test("cardStroke dark == #F7F2E8@12%")
    func cardStrokeDark() {
        let color = resolve(NSColor.cardStroke, appearance: .darkAqua)
        assertSRGB(color, expected: SRGB(red: 0.969, green: 0.949, blue: 0.910, alpha: 0.12), label: "cardStroke dark")
    }

    @Test("wall dark == #110F09")
    func wallDark() {
        let color = resolve(Color.wall, appearance: .darkAqua)
        assertSRGB(color, expected: SRGB(red: 0.067, green: 0.059, blue: 0.035, alpha: 1), label: "wall dark")
    }

    @Test("sidebarTint dark == #14120D@74%")
    func sidebarTintDark() {
        let color = resolve(Color.sidebarTint, appearance: .darkAqua)
        assertSRGB(color, expected: SRGB(red: 0.078, green: 0.071, blue: 0.051, alpha: 0.74), label: "sidebarTint dark")
    }

    // Sage family

    @Test("sage dark == #86C295")
    func sageDark() {
        let color = resolve(NSColor.sage, appearance: .darkAqua)
        assertSRGB(color, expected: SRGB(red: 0.525, green: 0.761, blue: 0.584, alpha: 1), label: "sage dark")
    }

    @Test("accentWashSoft dark == #86C295@12%")
    func accentWashSoftDark() {
        let color = resolve(Color.accentWashSoft, appearance: .darkAqua)
        assertSRGB(color, expected: SRGB(red: 0.525, green: 0.761, blue: 0.584, alpha: 0.12), label: "accentWashSoft dark")
    }

    @Test("accentWashStrong dark == #86C295@16%")
    func accentWashStrongDark() {
        let color = resolve(NSColor.accentWashStrong, appearance: .darkAqua)
        assertSRGB(color, expected: SRGB(red: 0.525, green: 0.761, blue: 0.584, alpha: 0.16), label: "accentWashStrong dark")
    }

    @Test("softSageFill dark == #86C295@14%")
    func softSageFillDark() {
        let color = resolve(Color.softSageFill, appearance: .darkAqua)
        assertSRGB(color, expected: SRGB(red: 0.525, green: 0.761, blue: 0.584, alpha: 0.14), label: "softSageFill dark")
    }

    @Test("findHighlightFocused dark == #86C295@35%")
    func findHighlightFocusedDark() {
        let color = resolve(NSColor.findHighlightFocused, appearance: .darkAqua)
        assertSRGB(color, expected: SRGB(red: 0.525, green: 0.761, blue: 0.584, alpha: 0.35), label: "findHighlightFocused dark")
    }

    // Alert red

    @Test("signalRed dark == #E5604A")
    func signalRedDark() {
        let color = resolve(Color.signalRed, appearance: .darkAqua)
        assertSRGB(color, expected: SRGB(red: 0.898, green: 0.376, blue: 0.290, alpha: 1), label: "signalRed dark")
    }

    @Test("recordingOutline dark == #E5604A@36%")
    func recordingOutlineDark() {
        let color = resolve(Color.recordingOutline, appearance: .darkAqua)
        assertSRGB(color, expected: SRGB(red: 0.898, green: 0.376, blue: 0.290, alpha: 0.36), label: "recordingOutline dark")
    }

    // Amber

    @Test("warningOchre dark == #E8A13A")
    func warningOchreDark() {
        let color = resolve(Color.warningOchre, appearance: .darkAqua)
        assertSRGB(color, expected: SRGB(red: 0.910, green: 0.631, blue: 0.227, alpha: 1), label: "warningOchre dark")
    }

    @Test("warningChipText dark == #F0C04A")
    func warningChipTextDark() {
        let color = resolve(Color.warningChipText, appearance: .darkAqua)
        assertSRGB(color, expected: SRGB(red: 0.941, green: 0.753, blue: 0.290, alpha: 1), label: "warningChipText dark")
    }

    // New tokens

    @Test("cardFill dark == #1A170F")
    func cardFillDark() {
        let color = resolve(Color.cardFill, appearance: .darkAqua)
        assertSRGB(color, expected: SRGB(red: 0.102, green: 0.090, blue: 0.059, alpha: 1), label: "cardFill dark")
    }

    @Test("accentFill dark == #56906A")
    func accentFillDark() {
        let color = resolve(Color.accentFill, appearance: .darkAqua)
        assertSRGB(color, expected: SRGB(red: 0.337, green: 0.565, blue: 0.416, alpha: 1), label: "accentFill dark")
    }

    @Test("read dark == #F7F2E8@75%")
    func readDark() {
        let color = resolve(Color.read, appearance: .darkAqua)
        assertSRGB(color, expected: SRGB(red: 0.969, green: 0.949, blue: 0.910, alpha: 0.75), label: "read dark")
    }

    @Test("elevatedFill dark == #1A170F")
    func elevatedFillDark() {
        let color = resolve(Color.elevatedFill, appearance: .darkAqua)
        assertSRGB(color, expected: SRGB(red: 0.102, green: 0.090, blue: 0.059, alpha: 1), label: "elevatedFill dark")
    }

    @Test("accentTrack dark == #5E9A6F")
    func accentTrackDark() {
        let color = resolve(Color.accentTrack, appearance: .darkAqua)
        assertSRGB(color, expected: SRGB(red: 0.369, green: 0.604, blue: 0.435, alpha: 1), label: "accentTrack dark")
    }

    @Test("signalRedText dark == #F08A78")
    func signalRedTextDark() {
        let color = resolve(Color.signalRedText, appearance: .darkAqua)
        assertSRGB(color, expected: SRGB(red: 0.941, green: 0.541, blue: 0.471, alpha: 1), label: "signalRedText dark")
    }

    @Test("cardShadow dark == black@40%")
    func cardShadowDark() {
        let color = resolve(Color.cardShadow, appearance: .darkAqua)
        assertSRGB(color, expected: SRGB(red: 0, green: 0, blue: 0, alpha: 0.40), label: "cardShadow dark")
    }

    @Test("controlShadow dark == black@40%")
    func controlShadowDark() {
        let color = resolve(Color.controlShadow, appearance: .darkAqua)
        assertSRGB(color, expected: SRGB(red: 0, green: 0, blue: 0, alpha: 0.40), label: "controlShadow dark")
    }

    // Opacity-derived tokens: auto-adapt via their dynamic base color.
    // These validate that `.opacity()` on a dynamic Color resolves the
    // correct dark-mode base before applying the alpha multiplier.

    @Test("recordingTintSoft dark == #E5604A@8%")
    func recordingTintSoftDark() {
        let color = resolve(Color.recordingTintSoft, appearance: .darkAqua)
        assertSRGB(color, expected: SRGB(red: 0.898, green: 0.376, blue: 0.290, alpha: 0.08), label: "recordingTintSoft dark")
    }

    @Test("recordingTintStrong dark == #E5604A@12%")
    func recordingTintStrongDark() {
        let color = resolve(Color.recordingTintStrong, appearance: .darkAqua)
        assertSRGB(color, expected: SRGB(red: 0.898, green: 0.376, blue: 0.290, alpha: 0.12), label: "recordingTintStrong dark")
    }

    @Test("recordingOutlineStrong dark == #E5604A@20%")
    func recordingOutlineStrongDark() {
        let color = resolve(Color.recordingOutlineStrong, appearance: .darkAqua)
        assertSRGB(color, expected: SRGB(red: 0.898, green: 0.376, blue: 0.290, alpha: 0.20), label: "recordingOutlineStrong dark")
    }

    @Test("recordingHoverFill dark == #E5604A@5%")
    func recordingHoverFillDark() {
        let color = resolve(Color.recordingHoverFill, appearance: .darkAqua)
        assertSRGB(color, expected: SRGB(red: 0.898, green: 0.376, blue: 0.290, alpha: 0.05), label: "recordingHoverFill dark")
    }

    @Test("warningBackground dark == #E8A13A@15%")
    func warningBackgroundDark() {
        let color = resolve(Tokens.warningBackground, appearance: .darkAqua)
        assertSRGB(color, expected: SRGB(red: 0.910, green: 0.631, blue: 0.227, alpha: 0.15), label: "warningBackground dark")
    }

    @Test("errorBackground dark == #E5604A@15%")
    func errorBackgroundDark() {
        let color = resolve(Tokens.errorBackground, appearance: .darkAqua)
        assertSRGB(color, expected: SRGB(red: 0.898, green: 0.376, blue: 0.290, alpha: 0.15), label: "errorBackground dark")
    }
}

// MARK: - Test 3: Tokens aliases resolve correctly

@Suite("Tokens aliases resolve correctly")
struct TokensAliasTests {
    @Test("Tokens.cardFill light == white")
    func tokensCardFillLight() {
        let color = resolve(Tokens.cardFill, appearance: .aqua)
        assertSRGB(color, expected: SRGB(red: 1.0, green: 1.0, blue: 1.0, alpha: 1), label: "Tokens.cardFill light")
    }
}

// MARK: - Test 4: No colorScheme conditionals in view code

@Suite("No colorScheme conditionals in view code")
struct NoColorSchemeConditionalsTests {
    @Test("No @Environment colorScheme or colorScheme == in view sources")
    func noColorSchemeInViews() throws {
        // Find the Sources directory relative to this test file.
        // The repo structure is: Packages/BiscottiKit/Sources/... and .../Tests/...
        let testsDir = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        let biscottiKitDir = testsDir
            .deletingLastPathComponent() // Tests/
            .deletingLastPathComponent() // BiscottiKit/
        let sourcesDir = biscottiKitDir.appendingPathComponent("Sources")

        let fileManager = FileManager.default
        guard let enumerator = fileManager.enumerator(
            at: sourcesDir,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ) else {
            Issue.record("Could not enumerate Sources directory at \(sourcesDir.path)")
            return
        }

        var violations: [String] = []
        let dynamicColorFile = "DynamicColor.swift"

        while let url = enumerator.nextObject() as? URL {
            guard url.pathExtension == "swift" else { continue }
            let filename = url.lastPathComponent
            // The only allowed appearance logic lives in DynamicColor.swift.
            if filename == dynamicColorFile { continue }

            let contents = try String(contentsOf: url, encoding: .utf8)
            if contents.contains("colorScheme ==")
                || contents.contains("@Environment(\\.colorScheme)")
            {
                violations.append(filename)
            }
        }

        #expect(
            violations.isEmpty,
            "Files with colorScheme conditionals (should be zero): \(violations)"
        )
    }
}
