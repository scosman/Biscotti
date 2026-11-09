import Foundation

/// The classification of items in a drag hovering over the window.
/// Drives the drop overlay's visual state and copy.
public enum DropOverlayState: Equatable, Sendable {
    /// All items supported, count >= 1.
    case supported(count: Int)
    /// At least one of each: supported >= 1, unsupported >= 1.
    case mixed(supported: Int, unsupported: Int)
    /// Every item unsupported, count >= 1.
    case unsupported(count: Int)

    /// Classifies an array of support flags. Returns nil when the array
    /// is empty (no file items in the drag -- text, link, etc.).
    public static func classify(_ items: [Bool]) -> DropOverlayState? {
        guard !items.isEmpty else { return nil }
        let supportedCount = items.count(where: { $0 })
        let unsupportedCount = items.count - supportedCount
        if unsupportedCount == 0 {
            return .supported(count: supportedCount)
        } else if supportedCount == 0 {
            return .unsupported(count: unsupportedCount)
        } else {
            return .mixed(
                supported: supportedCount,
                unsupported: unsupportedCount
            )
        }
    }

    /// Whether the drop should be accepted (cursor shows "+").
    public var acceptsDrop: Bool {
        if case .unsupported = self { return false }
        return true
    }

    // MARK: - Copy

    /// The large title text.
    public var title: String {
        switch self {
        case .supported(1), .mixed(supported: 1, unsupported: _):
            "Drop to import"
        case let .supported(count):
            "Drop to import \(count) files"
        case let .mixed(supported, _):
            "Drop to import \(supported) files"
        case .unsupported:
            "Can\u{2019}t import this file"
        }
    }

    /// The subtitle below the title.
    public var subtitle: String {
        switch self {
        case .supported(1):
            "Biscotti will transcribe and summarize it on your Mac."
        case .supported:
            "Each file becomes its own meeting."
        case .mixed:
            "Each file becomes its own meeting."
        case .unsupported:
            "Biscotti imports audio and video recordings."
        }
    }

    /// Whether to show the format line (WAV, MP3, ...).
    public var showsFormatLine: Bool {
        switch self {
        case .supported(1), .unsupported:
            true
        default:
            false
        }
    }

    /// The skip notice for mixed drags, nil otherwise.
    /// Returns the unsupported count and the full text.
    public var skipNotice: (count: Int, text: String)? {
        guard case let .mixed(_, unsupported) = self else { return nil }
        let noun = unsupported == 1
            ? "file is an unsupported file type and will be skipped."
            : "files are unsupported file types and will be skipped."
        return (unsupported, "\(unsupported) \(noun)")
    }

    /// Whether the overlay is in the neutral (unsupported) visual state.
    public var isNeutral: Bool {
        if case .unsupported = self { return true }
        return false
    }
}
