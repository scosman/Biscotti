import CoreText
import Foundation

/// Idempotent, preview-safe runtime registration of the bundled custom fonts.
///
/// Fonts are registered at process scope so they are available from any UI
/// package and in SwiftUI previews. The `ensure()` call is both called lazily
/// by the `Font.biscotti*` helpers (first use) and explicitly at app launch
/// so registration is warm before first paint.
public enum FontRegistration {
    /// PostScript names of the bundled fonts. These must match the names embedded
    /// in the TTF files. The font registration test verifies this.
    public static let registeredNames = [
        "JetBrainsMono-Regular",
        "JetBrainsMono-Medium",
        "NewsreaderDisplay-Medium"
    ]

    private static let _registerOnce: Void = {
        for name in registeredNames {
            guard let url = Bundle.module.url(forResource: name, withExtension: "ttf") else {
                continue
            }
            CTFontManagerRegisterFontsForURL(url as CFURL, .process, nil)
        }
    }()

    /// Ensure all bundled fonts are registered. Safe to call multiple times.
    public static func ensure() {
        _ = _registerOnce
    }
}
