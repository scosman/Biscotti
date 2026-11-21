import AppKit
import SwiftUI

/// The label (icon + optional text) shown in the macOS menu bar.
///
/// Uses custom SVG artwork from the app asset catalog. The images are
/// loaded as `NSImage` with an explicit point size because SwiftUI's
/// `MenuBarExtra` label ignores `.frame()` modifiers and falls back
/// to the SVG's intrinsic viewBox dimensions. Template rendering lets
/// macOS tint the icon for light/dark menu bars automatically.
public struct MenuBarLabelView: View {
    @Bindable var viewModel: MenuBarViewModel

    /// Asset catalog name for the idle menu-bar icon.
    public static let idleIconName = "MenuBarIcon"

    /// Asset catalog name for the recording menu-bar icon.
    public static let recordingIconName = "MenuBarIconRecording"

    /// Height in points for the menu-bar icon. Standard macOS status
    /// items are ~16pt tall; the width scales from the SVG aspect ratio.
    private static let iconHeight: CGFloat = 16

    public init(viewModel: MenuBarViewModel) {
        self.viewModel = viewModel
    }

    public var body: some View {
        HStack(spacing: 4) {
            menuBarIcon
            if viewModel.isRecording {
                // Live elapsed timer next to the icon.
                Text(viewModel.elapsedText)
                    .font(.caption)
                    .monospacedDigit()
            } else if case let .nextMeeting(title, time) = viewModel
                .iconState
            {
                Text("\(title) \u{2013} \(time)")
                    .font(.caption)
                    .monospacedDigit()
            }
        }
    }

    private var menuBarIcon: some View {
        let name = viewModel.iconState == .recording
            ? Self.recordingIconName
            : Self.idleIconName
        return Image(
            nsImage: Self.menuBarNSImage(named: name)
        )
    }

    /// Load an asset-catalog image sized for the menu bar.
    ///
    /// `MenuBarExtra` labels ignore SwiftUI frame modifiers, so we
    /// must set the `NSImage.size` explicitly. The image is marked as
    /// a template so macOS applies the correct menu-bar tint.
    public static func menuBarNSImage(
        named assetName: String
    ) -> NSImage {
        guard let original = NSImage(named: assetName) else {
            // Asset missing at runtime — return an empty image so the
            // menu bar still renders (avoids a force-unwrap crash).
            return NSImage()
        }

        // Copy so we don't mutate the shared catalog instance.
        guard let sized = original.copy() as? NSImage else {
            return original
        }
        let aspect = original.size.width / original.size.height
        sized.size = NSSize(
            width: iconHeight * aspect,
            height: iconHeight
        )
        sized.isTemplate = true
        return sized
    }
}
