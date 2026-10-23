import Foundation
import Testing
@testable import MCPServer

/// The `mcpServerPort` user-default override. Each test runs against its own
/// throwaway `UserDefaults` suite so nothing touches `.standard`.
@Suite("MCPServerConfiguration port override")
struct MCPServerConfigurationTests {
    /// Runs `body` with an empty suite and removes the suite afterwards.
    private func withDefaults(_ body: (UserDefaults) throws -> Void) throws {
        let name = "MCPServerConfigurationTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        try body(defaults)
    }

    @Test("no override uses the default port")
    func noOverride() throws {
        try withDefaults { defaults in
            #expect(MCPServerConfiguration.port(from: defaults) == MCPServerConfiguration.defaultPort)
        }
        #expect(MCPServerConfiguration.defaultPort == 8516)
    }

    @Test("an in-range integer override wins")
    func integerOverride() throws {
        try withDefaults { defaults in
            defaults.set(8517, forKey: MCPServerConfiguration.portDefaultsKey)
            #expect(MCPServerConfiguration.port(from: defaults) == 8517)
        }
    }

    @Test("a numeric string override is accepted")
    func stringOverride() throws {
        try withDefaults { defaults in
            defaults.set("9123", forKey: MCPServerConfiguration.portDefaultsKey)
            #expect(MCPServerConfiguration.port(from: defaults) == 9123)
        }
    }

    @Test("out-of-range overrides fall back to the default", arguments: [0, 80, 1023, 65536, -1])
    func outOfRange(value: Int) throws {
        try withDefaults { defaults in
            defaults.set(value, forKey: MCPServerConfiguration.portDefaultsKey)
            #expect(MCPServerConfiguration.port(from: defaults) == MCPServerConfiguration.defaultPort)
        }
    }

    @Test("a non-numeric override falls back to the default")
    func nonNumeric() throws {
        try withDefaults { defaults in
            defaults.set("not-a-port", forKey: MCPServerConfiguration.portDefaultsKey)
            #expect(MCPServerConfiguration.port(from: defaults) == MCPServerConfiguration.defaultPort)
        }
    }

    @Test("the endpoint URL carries the port")
    func endpointURL() {
        #expect(
            MCPServerConfiguration.endpointURL(port: 8517).absoluteString
                == "http://127.0.0.1:8517/mcp"
        )
    }
}
