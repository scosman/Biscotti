import Foundation

/// Shared state between the window drop target (AppKit) and the drop
/// overlay view (SwiftUI). Owned by `AppShellViewModel`.
@MainActor @Observable
public final class DropTargetModel {
    /// The current overlay state. Nil means the overlay is hidden
    /// (no qualifying drag in progress).
    public internal(set) var state: DropOverlayState?

    public init() {}
}
