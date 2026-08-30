import Foundation

/// Compile-time constants for the MCP server. Not user-configurable — a fixed
/// port is what makes the client config snippet copy-pasteable.
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
}
