import AppKit
import Foundation
import SwiftUI
import Testing
@testable import DesignSystem

// MARK: - Helpers

/// Resolved sRGB color components for comparison.
private struct SRGB {
    let red: CGFloat
    let green: CGFloat
    let blue: CGFloat
    let alpha: CGFloat
}

private func resolve(
    _ color: Color, appearance appearanceName: NSAppearance.Name
) -> SRGB {
    let nsColor = NSColor(color)
    var result = SRGB(red: 0, green: 0, blue: 0, alpha: 0)
    // swiftlint:disable:next force_unwrapping
    NSAppearance(named: appearanceName)!.performAsCurrentDrawingAppearance {
        // swiftlint:disable:next force_unwrapping
        let resolved = nsColor.usingColorSpace(.sRGB)!
        result = SRGB(
            red: resolved.redComponent,
            green: resolved.greenComponent,
            blue: resolved.blueComponent,
            alpha: resolved.alphaComponent
        )
    }
    return result
}

/// Sub-8-bit tolerance.
private let tolerance: CGFloat = 1.0 / 512.0

private func assertClose(
    _ actual: CGFloat, _ expected: CGFloat, label: String,
    sourceLocation: SourceLocation = #_sourceLocation
) {
    #expect(
        abs(actual - expected) <= tolerance,
        "\(label): expected \(expected), got \(actual)",
        sourceLocation: sourceLocation
    )
}

// MARK: - Tests

@Suite("Tag palette")
struct TagPaletteTests {
    @Test("tagSwatches has exactly 8 entries")
    func paletteCount() {
        #expect(Color.tagSwatches.count == 8)
    }

    @Test("tagSwatch wraps positive indices")
    func wrapPositive() {
        // Slot 9 should equal slot 1, slot 16 equals slot 0, etc.
        let swatch9 = resolve(Color.tagSwatch(slot: 9), appearance: .aqua)
        let swatch1 = resolve(Color.tagSwatch(slot: 1), appearance: .aqua)
        assertClose(swatch9.red, swatch1.red, label: "slot 9 vs 1 red")
        assertClose(swatch9.green, swatch1.green, label: "slot 9 vs 1 green")
        assertClose(swatch9.blue, swatch1.blue, label: "slot 9 vs 1 blue")

        let swatch16 = resolve(Color.tagSwatch(slot: 16), appearance: .aqua)
        let swatch0 = resolve(Color.tagSwatch(slot: 0), appearance: .aqua)
        assertClose(swatch16.red, swatch0.red, label: "slot 16 vs 0 red")
        assertClose(swatch16.green, swatch0.green, label: "slot 16 vs 0 green")
        assertClose(swatch16.blue, swatch0.blue, label: "slot 16 vs 0 blue")
    }

    @Test("tagSwatch wraps negative indices")
    func wrapNegative() {
        // Slot -1 should equal slot 7
        let swatchNeg1 = resolve(Color.tagSwatch(slot: -1), appearance: .aqua)
        let swatch7 = resolve(Color.tagSwatch(slot: 7), appearance: .aqua)
        assertClose(swatchNeg1.red, swatch7.red, label: "slot -1 vs 7 red")
        assertClose(swatchNeg1.green, swatch7.green, label: "slot -1 vs 7 green")
        assertClose(swatchNeg1.blue, swatch7.blue, label: "slot -1 vs 7 blue")

        // Slot -8 should equal slot 0
        let swatchNeg8 = resolve(Color.tagSwatch(slot: -8), appearance: .aqua)
        let swatch0 = resolve(Color.tagSwatch(slot: 0), appearance: .aqua)
        assertClose(swatchNeg8.red, swatch0.red, label: "slot -8 vs 0 red")
        assertClose(swatchNeg8.green, swatch0.green, label: "slot -8 vs 0 green")
        assertClose(swatchNeg8.blue, swatch0.blue, label: "slot -8 vs 0 blue")
    }

    @Test("Slot 4 matches signalRed in light mode")
    func slot4MatchesSignalRedLight() {
        let slot4 = resolve(Color.tagSwatch(slot: 4), appearance: .aqua)
        let red = resolve(Color.signalRed, appearance: .aqua)
        assertClose(slot4.red, red.red, label: "slot4 vs signalRed light red")
        assertClose(slot4.green, red.green, label: "slot4 vs signalRed light green")
        assertClose(slot4.blue, red.blue, label: "slot4 vs signalRed light blue")
        assertClose(slot4.alpha, red.alpha, label: "slot4 vs signalRed light alpha")
    }

    @Test("Slot 4 matches signalRed in dark mode")
    func slot4MatchesSignalRedDark() {
        let slot4 = resolve(Color.tagSwatch(slot: 4), appearance: .darkAqua)
        let red = resolve(Color.signalRed, appearance: .darkAqua)
        assertClose(slot4.red, red.red, label: "slot4 vs signalRed dark red")
        assertClose(slot4.green, red.green, label: "slot4 vs signalRed dark green")
        assertClose(slot4.blue, red.blue, label: "slot4 vs signalRed dark blue")
        assertClose(slot4.alpha, red.alpha, label: "slot4 vs signalRed dark alpha")
    }
}
