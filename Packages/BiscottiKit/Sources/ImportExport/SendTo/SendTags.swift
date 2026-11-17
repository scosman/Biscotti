import DataStore
import Foundation

/// Per-destination tag sanitization (functional spec §4).
public enum SendTags {
    /// Returns the sanitized, deduped tag list for a destination.
    /// `biscotti` is always first, then the meeting's tags sorted
    /// case-insensitively. Any meeting tag equal to `biscotti`
    /// (case-insensitive) is dropped.
    public static func tags(_ raw: [String], for destination: ExportDestination) -> [String] {
        var seen: Set<String> = []
        var result = ["biscotti"]
        seen.insert("biscotti")

        let sanitized = raw.compactMap { tag -> String? in
            let cleaned = sanitize(tag, for: destination)
            guard !cleaned.isEmpty else { return nil }
            return cleaned
        }

        let sorted = sanitized.sorted {
            $0.lowercased() < $1.lowercased()
        }

        for tag in sorted {
            let key = tag.lowercased()
            if key == "biscotti" { continue }
            if seen.insert(key).inserted {
                result.append(tag)
            }
        }

        return result
    }

    // MARK: - Per-destination sanitization

    private static func sanitize(_ tag: String, for destination: ExportDestination) -> String {
        switch destination {
        case .bear: sanitizeBear(tag)
        case .obsidian: sanitizeObsidian(tag)
        case .appleNotes: sanitizeAppleNotes(tag)
        }
    }

    /// Bear: trim, whitespace runs -> `-`, remove `,` and `#`, keep `/`.
    private static func sanitizeBear(_ tag: String) -> String {
        var result = tag.trimmingCharacters(in: .whitespacesAndNewlines)
        result = collapseWhitespace(result)
        result = String(result.unicodeScalars.filter { $0 != "," && $0 != "#" })
        return result.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Obsidian: trim, whitespace runs -> `-`, keep letters/digits/`_`/`-`/`/`,
    /// trim `/` at ends. A digits-only tag gets prefix `t`.
    private static func sanitizeObsidian(_ tag: String) -> String {
        var result = tag.trimmingCharacters(in: .whitespacesAndNewlines)
        result = collapseWhitespace(result)
        result = String(result.unicodeScalars.filter { scalar in
            CharacterSet.letters.contains(scalar)
                || CharacterSet.decimalDigits.contains(scalar)
                || CharacterSet.nonBaseCharacters.contains(scalar)
                || scalar == "_" || scalar == "-" || scalar == "/"
        })
        // Trim `/` at both ends
        while result.hasPrefix("/") {
            result.removeFirst()
        }
        while result.hasSuffix("/") {
            result.removeLast()
        }

        // Digits-only tag gets `t` prefix
        if !result.isEmpty, result.allSatisfy(\.isNumber) {
            result = "t" + result
        }
        return result
    }

    /// Apple Notes: trim, whitespace runs -> `-`, keep letters/digits/`_`/`-`.
    private static func sanitizeAppleNotes(_ tag: String) -> String {
        var result = tag.trimmingCharacters(in: .whitespacesAndNewlines)
        result = collapseWhitespace(result)
        result = String(result.unicodeScalars.filter { scalar in
            CharacterSet.letters.contains(scalar)
                || CharacterSet.decimalDigits.contains(scalar)
                || CharacterSet.nonBaseCharacters.contains(scalar)
                || scalar == "_" || scalar == "-"
        })
        return result
    }

    /// Replace runs of whitespace with a single `-`.
    private static func collapseWhitespace(_ input: String) -> String {
        var result = ""
        var lastWasSpace = false
        for char in input {
            if char.isWhitespace {
                if !lastWasSpace {
                    result.append("-")
                    lastWasSpace = true
                }
            } else {
                result.append(char)
                lastWasSpace = false
            }
        }
        return result
    }
}
