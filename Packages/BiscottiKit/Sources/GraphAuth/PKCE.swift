import CryptoKit
import Foundation

/// Proof Key for Code Exchange (RFC 7636) with the S256 method. A public
/// client has no secret, so the verifier is what ties the token request to
/// the browser session that produced the code.
struct PKCE: Equatable {
    let verifier: String
    let challenge: String

    /// A verifier from `verifier`, e.g. the RFC 7636 appendix B vector.
    init(verifier: String) {
        self.verifier = verifier
        challenge = Data(SHA256.hash(data: Data(verifier.utf8))).base64URLEncodedString()
    }

    /// A fresh verifier: 32 random bytes, 43 base64url characters.
    static func generate() -> PKCE {
        PKCE(verifier: randomURLSafeString(byteCount: 32))
    }
}

/// `byteCount` bytes from the system CSPRNG, base64url-encoded. Used for the
/// PKCE verifier, `state` and `nonce`.
func randomURLSafeString(byteCount: Int) -> String {
    var generator = SystemRandomNumberGenerator()
    let bytes = (0 ..< byteCount).map { _ in UInt8.random(in: .min ... .max, using: &generator) }
    return Data(bytes).base64URLEncodedString()
}

extension Data {
    /// Base64url without padding (RFC 4648 §5), as PKCE and JWTs use.
    func base64URLEncodedString() -> String {
        base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    /// Decodes base64url with or without padding.
    init?(base64URLEncoded string: String) {
        var base64 = string
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        base64 += String(repeating: "=", count: (4 - base64.count % 4) % 4)
        self.init(base64Encoded: base64)
    }
}
