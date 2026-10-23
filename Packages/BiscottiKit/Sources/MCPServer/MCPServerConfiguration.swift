import Foundation

/// Constants for the MCP server. The port defaults to 8516 and can be
/// overridden per machine with the `mcpServerPort` user default, so this
/// build and upstream Biscotti can both run without a bind conflict. The
/// Port field under Settings → General → MCP writes it and moves the running
/// server at once (`MCPServerController.setPort`). It can also be set from
/// the command line, which takes effect on the next launch:
///
///     defaults write com.synderys.biscotti mcpServerPort -int 8517
public enum MCPServerConfiguration {
    public static let host = "127.0.0.1"
    public static let defaultPort = 8516
    /// User-defaults key that overrides `defaultPort`.
    public static let portDefaultsKey = "mcpServerPort"
    /// Overrides outside this range fall back to `defaultPort`. 0 is excluded
    /// because an ephemeral port would make the advertised URL unknowable.
    public static let allowedPortRange = 1024 ... 65535
    public static let path = "/mcp"

    /// The port the app binds: the `mcpServerPort` override when it is set
    /// and in range, otherwise `defaultPort`.
    public static var port: Int {
        port(from: .standard)
    }

    /// The port configured in `defaults`. Split out so tests can pass an
    /// isolated suite instead of the process-wide `.standard`.
    public static func port(from defaults: UserDefaults) -> Int {
        guard defaults.object(forKey: portDefaultsKey) != nil else { return defaultPort }
        let value = defaults.integer(forKey: portDefaultsKey)
        return allowedPortRange.contains(value) ? value : defaultPort
    }

    /// The endpoint URL for the configured port.
    public static var endpointURL: URL {
        endpointURL(port: port)
    }

    /// The endpoint URL for `port`. The fallback is unreachable for any
    /// `Int` port; it only satisfies the optional `URL(string:)`.
    public static func endpointURL(port: Int) -> URL {
        URL(string: "http://\(host):\(port)\(path)") ?? defaultEndpointURL
    }

    // No `force_unwrapping` disable command here (unlike
    // LocalLLM/Sources/LocalLLM/Sampling.swift): the pinned SwiftLint 0.63.3
    // does not flag call-result unwraps of a plain literal (`URL(string:
    // "...")!`), so the disable would be rejected as superfluous. It does
    // flag an interpolated one, hence the `??` above. If a SwiftLint bump
    // starts flagging this line, add the disable then.
    private static let defaultEndpointURL = URL(string: "http://127.0.0.1:8516/mcp")!

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
    static let defaultResultLimit = 20
}
