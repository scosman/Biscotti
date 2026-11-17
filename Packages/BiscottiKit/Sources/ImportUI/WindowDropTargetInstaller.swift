import AppKit
import AudioImport
import SwiftUI

/// NSViewRepresentable that installs a window-wide drag target and visual
/// overlay. The drag target (`WindowDropView`) is added to the window's
/// theme frame so it covers the **entire** window — including the toolbar
/// and titlebar strip. The visual overlay (`DropOverlayView`) is hosted in
/// a transparent child panel managed by `WindowDropView`.
public struct WindowDropTargetInstaller: NSViewRepresentable {
    let model: DropTargetModel
    let isEnabled: @MainActor () -> Bool
    let onDrop: @MainActor ([ImportEntry]) -> Void

    public init(
        model: DropTargetModel,
        isEnabled: @escaping @MainActor () -> Bool,
        onDrop: @escaping @MainActor ([ImportEntry]) -> Void
    ) {
        self.model = model
        self.isEnabled = isEnabled
        self.onDrop = onDrop
    }

    public func makeNSView(context _: Context) -> DropTargetInstallerView {
        let view = DropTargetInstallerView()
        view.configure(model: model, isEnabled: isEnabled, onDrop: onDrop)
        return view
    }

    public func updateNSView(
        _ nsView: DropTargetInstallerView, context _: Context
    ) {
        nsView.configure(model: model, isEnabled: isEnabled, onDrop: onDrop)
    }
}

/// Zero-size helper hosted in the SwiftUI hierarchy. When it enters a
/// window it installs a `WindowDropView` on the window's theme frame
/// (the superview of `contentView`), which covers the entire window —
/// including the toolbar and titlebar strip. The `WindowDropView`'s own
/// `viewDidMoveToWindow` then creates the visual-overlay child panel.
///
/// When the view leaves the window the drop view is removed and the
/// panel is detached.
public final class DropTargetInstallerView: NSView {
    /// The drag-target view installed on the theme frame.
    /// Internal for testing.
    var dropView: WindowDropView?

    // Stored configuration, applied immediately when the drop view exists
    // and deferred until viewDidMoveToWindow otherwise.
    private var storedModel: DropTargetModel?
    private var storedIsEnabled: (@MainActor () -> Bool)?
    private var storedOnDrop: (@MainActor ([ImportEntry]) -> Void)?

    func configure(
        model: DropTargetModel,
        isEnabled: @escaping @MainActor () -> Bool,
        onDrop: @escaping @MainActor ([ImportEntry]) -> Void
    ) {
        storedModel = model
        storedIsEnabled = isEnabled
        storedOnDrop = onDrop
        dropView?.model = model
        dropView?.isEnabled = isEnabled
        dropView?.onDrop = onDrop
    }

    override public func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if let window,
           dropView == nil,
           let themeFrame = window.contentView?.superview,
           let model = storedModel
        {
            let view = WindowDropView(frame: themeFrame.bounds)
            view.autoresizingMask = [.width, .height]
            view.model = model
            view.isEnabled = storedIsEnabled ?? { true }
            view.onDrop = storedOnDrop ?? { _ in }
            // TODO: Investigate avoiding the AppKit "adding an unknown
            // subview" warning from installing the drop view on the theme
            // frame (NSThemeFrame logs the warning for any non-standard
            // subview). Functional -- log noise only.
            themeFrame.addSubview(view)
            dropView = view
        } else if window == nil {
            dropView?.removeFromSuperview()
            dropView = nil
        }
    }
}
