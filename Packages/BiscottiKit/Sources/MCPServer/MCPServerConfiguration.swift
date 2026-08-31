import Foundation

/// Compile-time constants for the MCP server. Not user-configurable — a
/// fixed port is what keeps the endpoint URL the settings sheet and the
/// connection guide show stable.
public enum MCPServerConfiguration {
    public static let host = "127.0.0.1"
    public static let port = 8516
    public static let path = "/mcp"
    // No `force_unwrapping` disable command here (unlike
    // LocalLLM/Sources/LocalLLM/Sampling.swift): the pinned SwiftLint 0.63.3
    // does not flag call-result unwraps (`URL(...)!`), so the disable would
    // be rejected as superfluous. If a SwiftLint bump starts flagging call
    // results, add the disable then.
    public static let endpointURL = URL(string: "http://127.0.0.1:8516/mcp")!

    static let maxBodyBytes = 1_048_576
    static let maxConcurrentConnections = 16
    static let idleTimeoutSeconds: Int64 = 120
    /// Ranked candidates drawn from the FTS index before a date filter is
    /// applied (architecture §6.1). Bounds the known limitation where a date
    /// range matching only very low-ranked results could miss them.
    static let searchCandidatePool = 500
    /// Maximum number of results `biscotti_query_meetings` accepts; the
    /// schema and description say 1-250 (functional spec §5.1).
    static let maxResultLimit = 250
    /// The limit applied when the caller sends none (functional spec §5.1).
    static let defaultResultLimit = 50
}
