import Foundation

/// ISO-8601 formatting for the CSV import/export surface (functional spec §1.3).
///
/// Rendering is always UTC with millisecond precision. Parsing is lenient:
/// it accepts the rendered form, second-precision ISO-8601, a bare epoch
/// integer (seconds or milliseconds), or a bare calendar date at local
/// midnight — so CSVs from other apps and scripts import without editing.
public enum ISO8601Formatting {
    /// `"2026-01-03T14:26:42.017Z"` — UTC, milliseconds, always.
    ///
    /// `ISO8601DateFormatter` is created per call — it is not `Sendable`,
    /// so a cached `static let` would not compile under Swift 6 strict
    /// concurrency, and the cost is irrelevant next to file I/O. It is
    /// preferred over `Date.ISO8601FormatStyle` because the format style
    /// truncates sub-millisecond `Date` error downward (a `.017` instant
    /// renders `.016`), which would not round-trip through parse.
    public static func string(from date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        formatter.timeZone = TimeZone(identifier: "UTC")
        return formatter.string(from: date)
    }

    /// Lenient parse per functional spec §1.3, in order:
    /// ISO-8601 with fractional seconds; ISO-8601 without; a whole-string
    /// integer (epoch — milliseconds when `abs(value) >= 100_000_000_000`,
    /// otherwise seconds); a whole-string `yyyy-MM-dd` date at local
    /// midnight. Nil when nothing matches.
    public static func date(from string: String) -> Date? {
        let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        if let dateTime = parseDateTime(trimmed) {
            return dateTime
        }

        // The bare-integer branch must match the whole string so a value
        // like "12:30" or "2026x" is never mistaken for an epoch count.
        if let value = Int(trimmed), trimmed.wholeMatch(of: /-?\d+/) != nil {
            let seconds = abs(value) >= epochMillisecondsThreshold
                ? Double(value) / 1000
                : Double(value)
            return Date(timeIntervalSince1970: seconds)
        }

        // The bare-date branch must match the whole string:
        // ISO8601DateFormatter parses a `yyyy-MM-dd` *prefix* and ignores
        // trailing characters, so a zone-less datetime would silently lose
        // its time component instead of being rejected (the
        // ToolDateFormatting precedent).
        guard trimmed.wholeMatch(of: /\d{4}-\d{2}-\d{2}/) != nil else { return nil }

        let dateFormatter = ISO8601DateFormatter()
        dateFormatter.formatOptions = [.withFullDate]
        // Local midnight: ISO8601DateFormatter defaults to GMT, so pin the
        // zone explicitly for the calendar day to land in the user's zone.
        dateFormatter.timeZone = TimeZone.current
        return dateFormatter.date(from: trimmed)
    }

    // MARK: - Internals

    /// 1e11 seconds is the year 5138, so anything at or above the threshold
    /// can only be epoch milliseconds (functional spec §1.3).
    private static let epochMillisecondsThreshold = 100_000_000_000

    private static func parseDateTime(_ string: String) -> Date? {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = formatter.date(from: string) {
            return date
        }
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: string)
    }
}
