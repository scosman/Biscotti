import Foundation

/// The lifecycle state of the MCP server, observed by SettingsUI (Phase 3).
/// The row shows intent + truth: the toggle is the user's intent, this enum
/// is the reality the caption renders.
public enum MCPServerState: Sendable, Equatable {
    /// Nothing is bound, allocated, or scheduled.
    case stopped
    case starting
    case running(URL)
    case failed(MCPServerStartError)
}

/// Why `start()` could not reach `.running`.
public enum MCPServerStartError: Error, Sendable, Equatable {
    /// The configured port is already bound by another process.
    case portInUse(port: Int)
    /// Any other bind/listener/start failure; the message is safe to display.
    case bindFailed(String)

    /// The exact Settings caption strings (functional spec §2.3). SettingsUI
    /// renders these verbatim and never composes error prose itself.
    public var userMessage: String {
        switch self {
        case let .portInUse(port):
            "Couldn't start: port \(port) is already in use by another app."
        case let .bindFailed(reason):
            "Couldn't start the MCP server. \(reason)"
        }
    }
}
