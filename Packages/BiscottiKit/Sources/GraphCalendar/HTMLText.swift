import Foundation

/// Converts Outlook event bodies (HTML) to the plain text EventKit would
/// show in `notes`. Regex-based on purpose: `NSAttributedString`'s HTML
/// importer needs the main thread and WebKit, and the bodies only need to
/// be readable and searchable for join links, not faithfully rendered.
public enum HTMLText {
    /// Notes longer than this are cut and end in `…`.
    public static let defaultLimit = 10000

    /// Plain text for `html`, capped at `limit` characters. Links keep their
    /// target as ` text href ` so a join link that only appears as an
    /// `href` is still visible to conference detection, with spaces on both
    /// sides because `MeetingCatalog` patterns run to the next whitespace.
    public static func plainText(fromHTML html: String, limit: Int? = defaultLimit) -> String {
        var text = html
        for rule in removalRules {
            text = rule.regex.stringByReplacingMatches(
                in: text, range: NSRange(text.startIndex..., in: text), withTemplate: rule.template
            )
        }
        text = replaceAnchors(in: text)
        for rule in structureRules {
            text = rule.regex.stringByReplacingMatches(
                in: text, range: NSRange(text.startIndex..., in: text), withTemplate: rule.template
            )
        }
        text = decodeEntities(text)
        text = normalizeWhitespace(text)
        guard let limit else { return text }
        return truncate(text, to: limit)
    }

    /// Normalizes a `text`-type body: same whitespace rules and cap as HTML.
    public static func plainText(fromText text: String, limit: Int? = defaultLimit) -> String {
        let normalized = normalizeWhitespace(text)
        guard let limit else { return normalized }
        return truncate(normalized, to: limit)
    }

    // MARK: - Rules

    private struct Rule {
        let regex: NSRegularExpression
        let template: String
    }

    private static func rules(_ specs: [(String, String)]) -> [Rule] {
        specs.compactMap { pattern, template in
            guard let regex = try? NSRegularExpression(
                pattern: pattern, options: [.caseInsensitive, .dotMatchesLineSeparators]
            ) else {
                assertionFailure("Invalid HTMLText pattern: \(pattern)")
                return nil
            }
            return Rule(regex: regex, template: template)
        }
    }

    /// Content that is never shown: comments (Outlook's conditional
    /// comments carry CSS), `<head>`, `<style>`, `<script>`.
    private static let removalRules = rules([
        (#"<!--.*?-->"#, ""),
        (#"<head\b.*?</head\s*>"#, ""),
        (#"<style\b.*?</style\s*>"#, ""),
        (#"<script\b.*?</script\s*>"#, "")
    ])

    /// Line structure, then every remaining tag. Source newlines are layout
    /// noise in HTML, so they become spaces before `<br>`/block ends add the
    /// real ones. `</li>` adds none: the next `<li>` or the list's end does,
    /// which keeps list items on consecutive lines.
    private static let structureRules = rules([
        (#"[\r\n]+"#, " "),
        (#"<br\s*/?>"#, "\n"),
        (#"<li\b[^>]*>"#, "\n- "),
        (#"</(p|div|tr|ul|ol|table|h[1-6]|blockquote)\s*>"#, "\n"),
        (#"<(p|div|tr|table|h[1-6]|blockquote)\b[^>]*>"#, "\n"),
        (#"</t[dh]\s*>"#, " "),
        (#"<[^>]+>"#, "")
    ])

    private static let anchorRegex = rules([
        (#"<a\b[^>]*?\bhref\s*=\s*(?:"([^"]*)"|'([^']*)'|([^\s>]+))[^>]*>(.*?)</a\s*>"#, "")
    ]).first

    private static let tagRegex = rules([(#"<[^>]+>"#, "")]).first

    private static let numericEntityRegex = rules([(#"&#(x?)([0-9a-f]+);"#, "")]).first

    private static let namedEntities: [String: String] = [
        "&nbsp;": " ", "&lt;": "<", "&gt;": ">", "&quot;": "\"", "&apos;": "'",
        "&ndash;": "–", "&mdash;": "—", "&hellip;": "…",
        "&rsquo;": "’", "&lsquo;": "‘", "&rdquo;": "”", "&ldquo;": "“",
        "&bull;": "•", "&middot;": "·", "&copy;": "©", "&reg;": "®", "&trade;": "™"
    ]

    // MARK: - Steps

    /// `<a href="u">t</a>` → ` t u ` (or ` u ` when the text is the URL or
    /// empty). Runs before tags are stripped so the href survives.
    private static func replaceAnchors(in text: String) -> String {
        guard let anchorRegex = anchorRegex?.regex else { return text }
        var result = ""
        var cursor = text.startIndex
        for match in anchorRegex.matches(in: text, range: NSRange(text.startIndex..., in: text)) {
            guard let whole = Range(match.range, in: text) else { continue }
            result += text[cursor ..< whole.lowerBound]
            cursor = whole.upperBound
            let href = (1 ... 3).lazy
                .compactMap { Range(match.range(at: $0), in: text).map { String(text[$0]) } }
                .first ?? ""
            let inner = Range(match.range(at: 4), in: text).map { String(text[$0]) } ?? ""
            // Compared decoded, inserted raw: every entity is decoded once,
            // at the end of `plainText`.
            let label = stripTags(inner).trimmingCharacters(in: .whitespacesAndNewlines)
            let target = href.trimmingCharacters(in: .whitespaces)
            let decodedTarget = decodeEntities(target)
            if decodedTarget.isEmpty || decodedTarget.lowercased().hasPrefix("mailto:")
                || decodedTarget.hasPrefix("#") || decodeEntities(label) == decodedTarget
            {
                result += " \(label.isEmpty ? target : label) "
            } else if label.isEmpty {
                result += " \(target) "
            } else {
                result += " \(label) \(target) "
            }
        }
        result += text[cursor...]
        return result
    }

    private static func stripTags(_ text: String) -> String {
        guard let tagRegex = tagRegex?.regex else { return text }
        return tagRegex.stringByReplacingMatches(in: text, range: NSRange(text.startIndex..., in: text), withTemplate: "")
    }

    /// Decodes numeric (`&#160;`, `&#xA0;`) and common named entities once,
    /// with `&amp;` last so `&amp;lt;` stays `&lt;`.
    static func decodeEntities(_ text: String) -> String {
        guard text.contains("&") else { return text }
        var result = text
        if let numericEntityRegex = numericEntityRegex?.regex {
            var decoded = ""
            var cursor = result.startIndex
            for match in numericEntityRegex.matches(in: result, range: NSRange(result.startIndex..., in: result)) {
                guard let whole = Range(match.range, in: result),
                      let hexFlag = Range(match.range(at: 1), in: result),
                      let digits = Range(match.range(at: 2), in: result)
                else { continue }
                let radix = result[hexFlag].isEmpty ? 10 : 16
                guard let value = UInt32(result[digits], radix: radix), let scalar = Unicode.Scalar(value) else {
                    continue
                }
                decoded += result[cursor ..< whole.lowerBound]
                decoded.unicodeScalars.append(scalar)
                cursor = whole.upperBound
            }
            decoded += result[cursor...]
            result = decoded
        }
        for (entity, replacement) in namedEntities {
            result = result.replacingOccurrences(of: entity, with: replacement, options: .caseInsensitive)
        }
        return result.replacingOccurrences(of: "&amp;", with: "&", options: .caseInsensitive)
    }

    /// NBSP and tabs to spaces, runs of spaces collapsed, lines trimmed, at
    /// most one blank line in a row, no leading/trailing blank lines.
    static func normalizeWhitespace(_ text: String) -> String {
        let unified = text
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
            .replacingOccurrences(of: "\u{00A0}", with: " ")
            .replacingOccurrences(of: "\t", with: " ")
        var lines: [String] = []
        var previousBlank = true
        for rawLine in unified.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = rawLine.split(separator: " ", omittingEmptySubsequences: true).joined(separator: " ")
            if line.isEmpty {
                if !previousBlank { lines.append("") }
                previousBlank = true
            } else {
                lines.append(line)
                previousBlank = false
            }
        }
        while lines.last == "" {
            lines.removeLast()
        }
        return lines.joined(separator: "\n")
    }

    private static func truncate(_ text: String, to limit: Int) -> String {
        guard text.count > limit else { return text }
        return String(text.prefix(max(limit - 1, 0))) + "…"
    }
}
