import os

/// Shared logger for the MCP server. Lifecycle events at `info`; tool call
/// *shapes* (never content) at `debug`. The security contract (functional
/// spec §4) forbids logging queries, titles, snippets, transcript text, or
/// file paths.
let mcpServerLog = Logger(subsystem: "net.scosman.biscotti", category: "MCP")
