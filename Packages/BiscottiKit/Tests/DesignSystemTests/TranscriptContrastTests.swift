import AppKit
import SwiftUI
import Testing
@testable import DesignSystem

/// Text in every transcript bubble, including the unsettled tail, and the
/// gap and start markers must reach 4.5:1 against what is behind them, in
/// light and dark mode (ui_design.md, Accessibility). The bubble fills are
/// translucent, so each is composited over what is behind the list first:
/// `paper` in the Transcript tab, `cardFill` in the live drawer.
@Suite("Transcript text contrast")
struct TranscriptContrastTests {
    private static let minimumRatio = 4.5
    private static let appearances: [NSAppearance.Name] = [.aqua, .darkAqua]

    private struct RGB {
        var red: Double
        var green: Double
        var blue: Double

        /// `top` with its alpha drawn over this opaque color.
        func behind(_ top: (rgb: RGB, alpha: Double)) -> RGB {
            RGB(
                red: top.rgb.red * top.alpha + red * (1 - top.alpha),
                green: top.rgb.green * top.alpha + green * (1 - top.alpha),
                blue: top.rgb.blue * top.alpha + blue * (1 - top.alpha)
            )
        }

        /// WCAG relative luminance.
        var luminance: Double {
            func linear(_ channel: Double) -> Double {
                channel <= 0.040_45 ? channel / 12.92 : pow((channel + 0.055) / 1.055, 2.4)
            }
            return 0.2126 * linear(red) + 0.7152 * linear(green) + 0.0722 * linear(blue)
        }

        func contrast(with other: RGB) -> Double {
            let lighter = max(luminance, other.luminance)
            let darker = min(luminance, other.luminance)
            return (lighter + 0.05) / (darker + 0.05)
        }
    }

    private static func resolve(_ color: Color, _ appearance: NSAppearance.Name) -> (rgb: RGB, alpha: Double) {
        var result = (rgb: RGB(red: 0, green: 0, blue: 0), alpha: 0.0)
        // swiftlint:disable:next force_unwrapping
        NSAppearance(named: appearance)!.performAsCurrentDrawingAppearance {
            // swiftlint:disable:next force_unwrapping
            let resolved = NSColor(color).usingColorSpace(.sRGB)!
            result = (
                RGB(
                    red: Double(resolved.redComponent),
                    green: Double(resolved.greenComponent),
                    blue: Double(resolved.blueComponent)
                ),
                Double(resolved.alphaComponent)
            )
        }
        return result
    }

    /// The contrast of `text` drawn on `fill`, with the fill drawn on `base`
    /// (opaque).
    private static func ratio(
        text: Color,
        on fill: Color?,
        over base: Color = .paper,
        _ appearance: NSAppearance.Name
    ) -> Double {
        let opaque = resolve(base, appearance).rgb
        let background = fill.map { opaque.behind(resolve($0, appearance)) } ?? opaque
        return background.behind(resolve(text, appearance)).contrast(with: background)
    }

    /// The Transcript tab's list sits on the window; the drawer's on its card.
    private static let backgrounds = [("paper", Color.paper), ("cardFill", Tokens.cardFill)]

    @Test(
        "settled text and the unsettled tail reach 4.5:1 on both bubble fills, in the tab and the drawer",
        arguments: [("ink", Color.ink), ("inkSecondaryLegible", Color.inkSecondaryLegible)]
    )
    func bubbleTextContrast(name: String, text: Color) {
        let fills = [("neutralChip", Tokens.neutralChip), ("softSageFill", Tokens.softSageFill)]
        for appearance in Self.appearances {
            for (baseName, base) in Self.backgrounds {
                for (fillName, fill) in fills {
                    let ratio = Self.ratio(text: text, on: fill, over: base, appearance)
                    #expect(
                        ratio >= Self.minimumRatio,
                        "\(name) on \(fillName) over \(baseName) in \(appearance.rawValue): \(ratio)"
                    )
                }
            }
        }
    }

    /// Gap and start markers sit on the list's background. The drawer's
    /// status text, find count, placeholder and language menu label use the
    /// same token on its card.
    @Test("markers and the drawer's secondary text and language label reach 4.5:1 on the window and the drawer card")
    func markerContrast() {
        for appearance in Self.appearances {
            for (baseName, base) in Self.backgrounds {
                let ratio = Self.ratio(text: .inkSecondaryLegible, on: nil, over: base, appearance)
                #expect(ratio >= Self.minimumRatio, "inkSecondaryLegible on \(baseName) in \(appearance.rawValue): \(ratio)")
            }
        }
    }

    @Test("the light tail token is the faintest ink that keeps a 4.6:1 margin")
    func lightTailIsTheFaintestPassingInk() {
        let ink = Self.resolve(.ink, .aqua).rgb
        let tail = Self.resolve(.inkSecondaryLegible, .aqua)
        let paper = Self.resolve(.paper, .aqua).rgb
        let worstFill = [Tokens.neutralChip, Tokens.softSageFill]
            .map { paper.behind(Self.resolve($0, .aqua)) }
        func worstRatio(alpha: Double) -> Double {
            worstFill.map { $0.behind((ink, alpha)).contrast(with: $0) }.min() ?? 0
        }

        #expect(worstRatio(alpha: tail.alpha) >= 4.6)
        #expect(worstRatio(alpha: tail.alpha - 0.01) < 4.6)
    }
}
