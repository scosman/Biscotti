import AppKit
import Foundation

/// Template `NSImage`s for third-party export destinations.
///
/// Each image is loaded once from the SVG resources bundled in
/// `DesignSystem/Resources/Icons/` and cached for the process lifetime.
/// All access is `@MainActor` (NSImage is not Sendable).
@MainActor
public enum ExportIcons {
    /// The available export-destination icon variants.
    public enum Kind: String, CaseIterable, Sendable {
        case obsidian = "obsidian-outline"
        case bear = "bear-outline-plain"
        case appleNotes = "apple-notes-outline"
    }

    /// Image cache, populated on first access per kind.
    private static var cache: [Kind: NSImage] = [:]

    /// Returns a cached template `NSImage` for the given icon kind.
    public static func image(_ kind: Kind) -> NSImage {
        if let cached = cache[kind] {
            return cached
        }
        let img = loadImage(kind)
        cache[kind] = img
        return img
    }

    private static func loadImage(_ kind: Kind) -> NSImage {
        // Try flat resource first (Bundle.module.url without subdirectory),
        // then fall back to the "Icons" subdirectory.
        let url: URL? =
            Bundle.module.url(forResource: kind.rawValue, withExtension: "svg")
                ?? Bundle.module.url(
                    forResource: kind.rawValue, withExtension: "svg",
                    subdirectory: "Icons"
                )

        guard let url else {
            assertionFailure("ExportIcons: missing SVG resource \(kind.rawValue)")
            let empty = NSImage()
            empty.isTemplate = true
            return empty
        }

        guard let image = NSImage(contentsOf: url) else {
            assertionFailure("ExportIcons: failed to load SVG at \(url.path)")
            let empty = NSImage()
            empty.isTemplate = true
            return empty
        }

        image.isTemplate = true
        return image
    }
}
