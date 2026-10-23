import Foundation

/// RFC 3986 percent-encoding that allows only the unreserved set
/// (`A-Z a-z 0-9 - . _ ~`). Spaces become `%20`, never `+`.
/// This avoids `URLQueryItem`'s encoding, which allows characters
/// that some apps interpret as special.
public enum StrictPercentEncoder {
    /// The unreserved ASCII bytes that pass through unencoded.
    private static let unreserved: Set<UInt8> = {
        var set = Set<UInt8>()
        for byte in UInt8(ascii: "A") ... UInt8(ascii: "Z") {
            set.insert(byte)
        }
        for byte in UInt8(ascii: "a") ... UInt8(ascii: "z") {
            set.insert(byte)
        }
        for byte in UInt8(ascii: "0") ... UInt8(ascii: "9") {
            set.insert(byte)
        }
        set.insert(UInt8(ascii: "-"))
        set.insert(UInt8(ascii: "."))
        set.insert(UInt8(ascii: "_"))
        set.insert(UInt8(ascii: "~"))
        return set
    }()

    private static let hexDigits: [UInt8] = Array("0123456789ABCDEF".utf8)

    /// Percent-encode a string, allowing only `A-Z a-z 0-9 - . _ ~`.
    public static func encode(_ value: String) -> String {
        var result: [UInt8] = []
        result.reserveCapacity(value.utf8.count)
        for byte in value.utf8 {
            if unreserved.contains(byte) {
                result.append(byte)
            } else {
                result.append(UInt8(ascii: "%"))
                result.append(hexDigits[Int(byte >> 4)])
                result.append(hexDigits[Int(byte & 0x0F)])
            }
        }
        return String(bytes: result, encoding: .ascii) ?? ""
    }

    /// Build a `key=value&key=value` query string with strict encoding.
    public static func query(_ pairs: [(String, String)]) -> String {
        pairs.map { "\(encode($0.0))=\(encode($0.1))" }.joined(separator: "&")
    }
}
