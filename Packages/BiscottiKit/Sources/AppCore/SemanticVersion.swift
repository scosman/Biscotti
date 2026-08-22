/// Parses and compares semantic-style version strings.
///
/// Tolerates a leading `v`/`V`, any number of dot-separated numeric
/// components, and strips anything from the first `-` or `+` onward
/// (pre-release/build metadata). Missing trailing components are
/// treated as 0 (`v2.0` == `v2.0.0`). Non-numeric or empty strings
/// return `nil` (fail closed — do not claim an update is available
/// when either side cannot be parsed).
public struct SemanticVersion: Sendable, Equatable, Comparable {
    /// The parsed numeric components (e.g. `[2, 0, 1]` for `"v2.0.1"`).
    public let components: [Int]

    /// Parses a version string. Returns `nil` for unparseable input.
    public init?(_ string: String) {
        var raw = string.trimmingCharacters(in: .whitespacesAndNewlines)

        // Strip leading v/V
        if let first = raw.first, first == "v" || first == "V" {
            raw = String(raw.dropFirst())
        }

        // Strip pre-release (`-beta`) and build metadata (`+42`)
        if let idx = raw.firstIndex(where: { $0 == "-" || $0 == "+" }) {
            raw = String(raw[..<idx])
        }

        let parts = raw.split(separator: ".", omittingEmptySubsequences: false)
        guard !parts.isEmpty else { return nil }

        var parsed: [Int] = []
        for part in parts {
            guard let value = Int(part), value >= 0 else { return nil }
            parsed.append(value)
        }
        components = parsed
    }

    // MARK: - Equatable (trailing zeros are insignificant)

    public static func == (lhs: SemanticVersion, rhs: SemanticVersion) -> Bool {
        let count = max(lhs.components.count, rhs.components.count)
        for index in 0 ..< count {
            let left = index < lhs.components.count ? lhs.components[index] : 0
            let right = index < rhs.components.count ? rhs.components[index] : 0
            if left != right { return false }
        }
        return true
    }

    // MARK: - Comparable

    public static func < (lhs: SemanticVersion, rhs: SemanticVersion) -> Bool {
        let count = max(lhs.components.count, rhs.components.count)
        for index in 0 ..< count {
            let left = index < lhs.components.count ? lhs.components[index] : 0
            let right = index < rhs.components.count ? rhs.components[index] : 0
            if left < right { return true }
            if left > right { return false }
        }
        return false // equal
    }

    // MARK: - Display

    /// Human-readable version with a leading `v` (e.g. `"v2.0.1"`).
    public var displayString: String {
        "v" + components.map(String.init).joined(separator: ".")
    }
}
