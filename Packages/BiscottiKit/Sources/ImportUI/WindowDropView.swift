import AppKit
import AudioImport
import Foundation
import SwiftUI

/// AppKit drag destination covering the entire window — including the
/// toolbar/titlebar strip — when installed on the theme frame by
/// `DropTargetInstallerView`.
///
/// Click-through: returns nil from `hitTest(_:)` for all mouse/scroll/cursor
/// events so it never steals interaction from the toolbar or SwiftUI content.
/// Drag-destination lookup still finds it because external drags don't
/// generate mouse events.
///
/// Also owns an `OverlayPanel` — a borderless, transparent child window
/// that hosts the `DropOverlayView` above the entire parent window. The
/// panel uses `ignoresMouseEvents = true`, so all clicks and scrolling
/// pass through to the main window.
public final class WindowDropView: NSView {
    weak var model: DropTargetModel?
    var isEnabled: @MainActor () -> Bool = { true }
    var onDrop: @MainActor ([ImportEntry]) -> Void = { _ in }

    /// The serial queue where promise receivers deliver files.
    private static let promiseQueue: OperationQueue = {
        let queue = OperationQueue()
        queue.name = "net.scosman.biscotti.import-promises"
        queue.maxConcurrentOperationCount = 1
        queue.qualityOfService = .userInitiated
        return queue
    }()

    static let draggedTypes: [NSPasteboard.PasteboardType] = {
        var types: [NSPasteboard.PasteboardType] = [.fileURL]
        types += NSFilePromiseReceiver.readableDraggedTypes
            .map { NSPasteboard.PasteboardType($0) }
        return types
    }()

    private var cachedOperation: NSDragOperation = []

    /// The transparent child window hosting the visual overlay.
    /// Internal (not private) so tests can verify sizing.
    var overlayPanel: OverlayPanel?

    override public init(frame: NSRect) {
        super.init(frame: frame)
        registerForDraggedTypes(Self.draggedTypes)
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        fatalError("Not implemented")
    }

    // MARK: - Overlay panel lifecycle

    override public func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window == nil {
            // Leaving the window -- tear down the panel.
            overlayPanel?.detach()
            overlayPanel = nil
        }
        // Panel creation is deferred to ensureOverlayPanel() (called on
        // first drag enter) so no NSHostingView exists when idle.
    }

    /// Creates the overlay panel if it does not exist yet. Called on the
    /// first drag enter, keeping the NSHostingView out of memory until
    /// a drag actually starts.
    private func ensureOverlayPanel() {
        guard overlayPanel == nil, let window, let model else { return }
        let panel = OverlayPanel(model: model)
        panel.attach(to: window)
        overlayPanel = panel
    }

    // MARK: - Click-through

    override public func hitTest(_ point: NSPoint) -> NSView? {
        // Return nil for all non-drag event types. During an external drag,
        // our app receives no mouse events, so `currentEvent` is something
        // else (or nil). In-app left-mouse-dragged passes through too, which
        // is fine: Biscotti has no internal file drags.
        switch NSApp.currentEvent?.type {
        case .leftMouseDown, .leftMouseUp, .leftMouseDragged,
             .rightMouseDown, .rightMouseUp, .rightMouseDragged,
             .otherMouseDown, .otherMouseUp, .otherMouseDragged,
             .mouseMoved, .mouseEntered, .mouseExited, .scrollWheel,
             .cursorUpdate, .magnify, .rotate, .swipe, .smartMagnify,
             .pressure, .none:
            nil
        default:
            super.hitTest(point)
        }
    }

    override public func acceptsFirstMouse(for _: NSEvent?) -> Bool {
        false
    }

    override public func wantsPeriodicDraggingUpdates() -> Bool {
        false
    }

    // MARK: - NSDraggingDestination

    override public func draggingEntered(
        _ sender: any NSDraggingInfo
    ) -> NSDragOperation {
        guard isEnabled() else { return [] }

        // Create the overlay panel on first drag (lazy -- avoids hosting
        // an NSHostingView when idle) and sync its frame.
        ensureOverlayPanel()
        overlayPanel?.syncFrame()

        let descriptors = PasteboardClassifier.describe(sender.draggingPasteboard)
        let flags = PasteboardClassifier.supportedFlags(descriptors)
        let state = DropOverlayState.classify(flags)

        // NSView drag callbacks run on the main thread; assign directly
        // so prepareForDragOperation sees the state without a run-loop delay.
        model?.state = state

        if state?.acceptsDrop == true {
            cachedOperation = .copy
        } else {
            cachedOperation = []
        }
        return cachedOperation
    }

    override public func draggingUpdated(
        _: any NSDraggingInfo
    ) -> NSDragOperation {
        overlayPanel?.syncFrame()
        return cachedOperation
    }

    override public func draggingExited(_: (any NSDraggingInfo)?) {
        model?.state = nil
    }

    override public func draggingEnded(_: any NSDraggingInfo) {
        model?.state = nil
    }

    override public func prepareForDragOperation(
        _: any NSDraggingInfo
    ) -> Bool {
        model?.state?.acceptsDrop == true
    }

    override public func performDragOperation(
        _ sender: any NSDraggingInfo
    ) -> Bool {
        let entries = buildEntries(from: sender)
        model?.state = nil
        if !entries.isEmpty {
            onDrop(entries)
        }
        return !entries.isEmpty
    }

    override public func concludeDragOperation(
        _: (any NSDraggingInfo)?
    ) {
        model?.state = nil
    }

    // MARK: - Entry building

    private func buildEntries(
        from sender: any NSDraggingInfo
    ) -> [ImportEntry] {
        // Classify once -- returns descriptors and promise receivers together,
        // avoiding a second pasteboard read.
        let classification = PasteboardClassifier.classify(
            sender.draggingPasteboard
        )
        let flags = PasteboardClassifier.supportedFlags(
            classification.descriptors
        )
        let receivers = classification.promiseReceivers

        var entries: [ImportEntry] = []

        for (descriptor, isSupported) in zip(classification.descriptors, flags) {
            guard isSupported else { continue }

            switch descriptor.kind {
            case let .file(url):
                entries.append(.file(url))

            case let .promise(_, index) where index < receivers.count:
                let receiver = receivers[index]
                let displayName = receiver.fileNames.first
                let future = PromisedFile()

                // First-file-only: one future per receiver.
                // Extra callbacks beyond the first are ignored;
                // their delivered files are deleted.
                var callbackCount = 0
                let tempDir = FileManager.default.temporaryDirectory
                    .appendingPathComponent("Biscotti-Import")
                    .appendingPathComponent(UUID().uuidString)
                try? FileManager.default.createDirectory(
                    at: tempDir, withIntermediateDirectories: true
                )

                receiver.receivePromisedFiles(
                    atDestination: tempDir,
                    options: [:],
                    operationQueue: Self.promiseQueue
                ) { url, error in
                    callbackCount += 1
                    if callbackCount == 1 {
                        future.resolve(url: url, error: error)
                    } else {
                        // Extra file from multi-file promise: delete it.
                        try? FileManager.default.removeItem(at: url)
                    }
                }

                entries.append(
                    .promised(
                        displayName: displayName,
                        deliver: { try await future.value }
                    )
                )

            default:
                break
            }
        }

        return entries
    }
}

// MARK: - Overlay panel

/// A borderless, transparent child window that hosts the `DropOverlayView`
/// above the entire parent window — including the toolbar/titlebar strip.
///
/// `ignoresMouseEvents = true`: the panel is purely visual. All clicks,
/// scrolling, and cursor events pass through to the main window. Traffic-light
/// buttons remain clickable. Esc during a drag is handled by AppKit's drag
/// machinery (which calls `draggingExited` / `draggingEnded` on the drop view).
///
/// Internal (not private) so tests can verify sizing behaviour.
final class OverlayPanel: NSPanel {
    init(model: DropTargetModel) {
        super.init(
            contentRect: .zero,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: true
        )
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        level = .normal
        hidesOnDeactivate = false
        ignoresMouseEvents = true
        collectionBehavior = [.fullScreenAuxiliary, .transient]

        let hosting = NSHostingView(
            rootView: DropOverlayView(model: model)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        )
        // Prevent the hosting view from sizing itself to the SwiftUI
        // view's intrinsic content size (which is zero when the overlay
        // is hidden). The hosting view must fill the panel instead.
        hosting.sizingOptions = []
        contentView = hosting

        // Clip to match the parent window's rounded corners (10 pt on
        // macOS 15+, 0 in fullscreen — the radius is cosmetic, so a
        // fixed 10 is acceptable; fullscreen hides the overshoot).
        contentView?.wantsLayer = true
        contentView?.layer?.cornerRadius = 10
        contentView?.layer?.cornerCurve = .continuous
        contentView?.layer?.masksToBounds = true
    }

    /// Syncs the panel's frame to the parent window's frame.
    /// Called on attach, on drag enter, and on drag update.
    func syncFrame() {
        guard let parentWindow = parent else { return }
        setFrame(parentWindow.frame, display: true)
    }

    func attach(to parent: NSWindow) {
        setFrame(parent.frame, display: false)
        parent.addChildWindow(self, ordered: .above)
        // No notification observer — the window cannot be resized while a
        // system drag is active. syncFrame() is called on draggingEntered
        // and draggingUpdated, which is sufficient.
    }

    func detach() {
        parent?.removeChildWindow(self)
        // Release the hosting view synchronously so SwiftUI does not
        // schedule deferred updates against a panel that is about to
        // be deallocated (prevents SIGSEGV in sequential test runs).
        contentView = nil
        orderOut(nil)
    }
}
