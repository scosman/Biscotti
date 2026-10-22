import Foundation

/// A Codable representation of any Error, for persisting failures to JSON.
public struct ErrorInfo: Codable, Sendable, Equatable {
    public var domain: String
    public var code: Int
    public var description: String
    public var debugDescription: String

    public init(_ error: any Error) {
        let nsError = error as NSError
        domain = nsError.domain
        code = nsError.code
        description = nsError.localizedDescription
        debugDescription = String(reflecting: error)
    }

    public init(domain: String, code: Int, description: String, debugDescription: String) {
        self.domain = domain
        self.code = code
        self.description = description
        self.debugDescription = debugDescription
    }
}
