import Foundation
import Testing
@testable import GraphAuth

/// Where the registration comes from and what counts as valid.
@Suite("GraphAuthConfiguration")
struct GraphAuthConfigurationTests {
    private static let clientID = TestRegistration.clientID
    private static let tenantID = TestRegistration.tenantID

    /// A throwaway defaults domain, so tests never read the developer's own
    /// `com.synderys.biscotti` defaults.
    private static func defaults(_ values: [String: String] = [:]) throws -> UserDefaults {
        let suite = "GraphAuthConfigurationTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defaults.removePersistentDomain(forName: suite)
        for (key, value) in values {
            defaults.set(value, forKey: key)
        }
        return defaults
    }

    @Test("defaults win over Info.plist")
    func defaultsFirst() throws {
        let otherClient = "99999999-2222-3333-4444-555555555555"
        let configuration = try GraphAuthConfiguration.load(
            defaults: Self.defaults([GraphAuthConfiguration.clientIDKey: otherClient]),
            infoDictionary: [
                GraphAuthConfiguration.clientIDKey: Self.clientID,
                GraphAuthConfiguration.tenantKey: Self.tenantID
            ]
        )
        #expect(configuration.clientID == otherClient)
        #expect(configuration.tenant == Self.tenantID)
    }

    @Test("a blank Info.plist placeholder counts as missing")
    func blankPlaceholder() throws {
        #expect(throws: GraphAuthConfigurationError.missingClientID) {
            try GraphAuthConfiguration.load(
                defaults: Self.defaults(),
                infoDictionary: [GraphAuthConfiguration.clientIDKey: "  ", GraphAuthConfiguration.tenantKey: Self.tenantID]
            )
        }
        let configuration = try GraphAuthConfiguration.load(
            defaults: Self.defaults([GraphAuthConfiguration.tenantKey: Self.tenantID]),
            infoDictionary: [GraphAuthConfiguration.clientIDKey: " \(Self.clientID)\n", GraphAuthConfiguration.tenantKey: ""]
        )
        #expect(configuration.clientID == Self.clientID)
        #expect(configuration.tenant == Self.tenantID)
    }

    @Test("nothing configured reports a missing client ID")
    func nothingConfigured() throws {
        #expect(throws: GraphAuthConfigurationError.missingClientID) {
            try GraphAuthConfiguration.load(defaults: Self.defaults(), infoDictionary: nil)
        }
        #expect(throws: GraphAuthConfigurationError.missingTenant) {
            try GraphAuthConfiguration.load(
                defaults: Self.defaults([GraphAuthConfiguration.clientIDKey: Self.clientID]),
                infoDictionary: nil
            )
        }
    }

    @Test("the client ID must be a GUID")
    func clientIDIsGUID() {
        #expect(throws: GraphAuthConfigurationError.invalidClientID("biscotti")) {
            try GraphAuthConfiguration(clientID: "biscotti", tenant: Self.tenantID)
        }
    }

    @Test(
        "the tenant is a GUID or a domain",
        arguments: ["aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee", "synderys.com", "synderys.onmicrosoft.com", "my-org.co.uk"]
    )
    func validTenants(tenant: String) throws {
        let configuration = try GraphAuthConfiguration(clientID: Self.clientID, tenant: tenant)
        #expect(configuration.tenant == tenant)
    }

    @Test(
        "multi-tenant aliases and junk are rejected",
        arguments: ["common", "Organizations", "consumers", "synderys", "synderys..com", "evil.com/x", "a b.com"]
    )
    func invalidTenants(tenant: String) {
        #expect(throws: GraphAuthConfigurationError.invalidTenant(tenant)) {
            try GraphAuthConfiguration(clientID: Self.clientID, tenant: tenant)
        }
    }

    @Test("endpoints, redirect and scopes")
    func endpoints() throws {
        let configuration = try TestRegistration.configuration()
        #expect(
            configuration.authorizeEndpoint.absoluteString
                == "https://login.microsoftonline.com/\(Self.tenantID)/oauth2/v2.0/authorize"
        )
        #expect(
            configuration.tokenEndpoint.absoluteString
                == "https://login.microsoftonline.com/\(Self.tenantID)/oauth2/v2.0/token"
        )
        #expect(configuration.redirectURI.absoluteString == "msauth.com.synderys.biscotti://auth")
        #expect(configuration.callbackScheme == "msauth.com.synderys.biscotti")
        #expect(
            configuration.scopeParameter
                == "openid profile offline_access User.Read Calendars.Read Calendars.Read.Shared"
        )
        #expect(configuration.tenantIsID)
        #expect(try !GraphAuthConfiguration(clientID: Self.clientID, tenant: "synderys.com").tenantIsID)
    }

    @Test("missing registration has a message for the user")
    func userMessages() {
        #expect(GraphAuthConfigurationError.missingClientID.userMessage.contains("client and tenant IDs"))
        #expect(GraphAuthConfigurationError.invalidTenant("common").userMessage.contains("\u{201C}common\u{201D}"))
    }
}
