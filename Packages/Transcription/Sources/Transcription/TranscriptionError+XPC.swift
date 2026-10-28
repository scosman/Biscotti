import Foundation

/// Lets a `TranscriptionError` thrown in the worker reach the app as itself.
///
/// NSXPC sends an error as an `NSError`: a domain, a code and a property-list
/// `userInfo`. Without a fixed domain and the case in `userInfo`, the app
/// receives an opaque "TranscriptionError error N" and cannot tell a cancelled
/// pass from a failed one, or a missing live model from a broken one.
extension TranscriptionError: CustomNSError {
    public static let errorDomain = "net.scosman.biscotti.TranscriptionError"

    /// The error as JSON, a string so `NSError`'s secure coding accepts it.
    private static let encodedKey = "TranscriptionErrorJSON"

    public var errorUserInfo: [String: Any] {
        var info: [String: Any] = [NSLocalizedDescriptionKey: String(describing: self)]
        if let data = try? JSONEncoder().encode(self), let json = String(bytes: data, encoding: .utf8) {
            info[Self.encodedKey] = json
        }
        return info
    }

    /// Rebuilds an error that crossed XPC, or returns nil for any other error.
    public init?(bridged error: NSError) {
        guard error.domain == Self.errorDomain,
              let json = error.userInfo[Self.encodedKey] as? String,
              let decoded = try? JSONDecoder().decode(Self.self, from: Data(json.utf8))
        else { return nil }
        self = decoded
    }
}
