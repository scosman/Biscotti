import Foundation

/// ISO-8601 helpers for the tool surface (functional spec §5: dates in and
/// out are ISO-8601 strings; inputs also accept a bare date, interpreted as
/// local midnight).
///
/// Formatters are created per call: `ISO8601DateFormatter` is not statically
/// `Sendable`, so a cached `static let` would not compile under Swift 6
/// strict concurrency, and tool-call frequency makes the init cost irrelevant.
enum ToolDateFormatting {
    /// Formats a date as UTC with second precision, e.g. `2026-08-27T17:00:00Z`.
    static func format(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        formatter.timeZone = TimeZone(identifier: "UTC")
        return formatter.string(from: date)
    }

    /// Parses a full ISO-8601 date-time (zone required, fractional seconds
    /// accepted) or a bare `yyyy-MM-dd` date, interpreted as local midnight.
    /// Returns nil for anything else.
    static func parse(_ string: String) -> Date? {
        if let dateTime = parseDateTime(string) {
            return dateTime
        }

        // The bare-date branch must match the whole string: ISO8601DateFormatter
        // parses a `yyyy-MM-dd` *prefix* and ignores trailing characters, so a
        // zone-less datetime like 2026-08-30T14:03:00 would silently lose its
        // time component instead of being rejected.
        guard string.wholeMatch(of: /\d{4}-\d{2}-\d{2}/) != nil else { return nil }

        let dateFormatter = ISO8601DateFormatter()
        dateFormatter.formatOptions = [.withFullDate]
        // Local midnight: ISO8601DateFormatter defaults to GMT, so pin the
        // zone explicitly for the calendar day to land in the user's zone.
        dateFormatter.timeZone = TimeZone.current
        return dateFormatter.date(from: string)
    }

    private static func parseDateTime(_ string: String) -> Date? {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        if let date = formatter.date(from: string) {
            return date
        }
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.date(from: string)
    }
}
