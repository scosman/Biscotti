import Foundation

/// Date handling for Graph's `dateTimeTimeZone` and `Edm.DateTimeOffset`
/// values. Hand-parsed rather than through `DateFormatter`: Graph sends 7
/// fractional digits, which no format string covers, and this keeps the
/// mapper free of non-Sendable formatter state.
enum GraphDateParsing {
    /// Wall-clock fields of a `yyyy-MM-ddTHH:mm:ss[.fffffff]` string.
    struct WallClock: Equatable {
        let year: Int
        let month: Int
        let day: Int
        let hour: Int
        let minute: Int
        let second: Int
        let fraction: Double
    }

    /// Zone names Graph uses for UTC, besides IANA's `UTC`/`Etc/UTC`.
    private static let utcAliases: Set<String> = [
        "utc", "etc/utc", "gmt", "coordinated universal time", "tzone://microsoft/utc"
    ]

    /// The instant a `dateTimeTimeZone` names. `timeZone` is normally `UTC`
    /// (the client sends `Prefer: outlook.timezone="UTC"`); an IANA or a
    /// known Windows zone name is also accepted.
    static func date(from value: Graph.DateTimeTimeZone) throws -> Date {
        let zoneName = value.timeZone ?? "UTC"
        guard let zone = timeZone(named: zoneName) else {
            throw GraphMappingError.unknownTimeZone(zoneName)
        }
        guard let wall = wallClock(value.dateTime), let instant = date(from: wall, in: zone) else {
            throw GraphMappingError.invalidDateTime(value.dateTime)
        }
        return instant
    }

    /// Local midnight, in `zone`, of the day an all-day event's start or
    /// end names. All-day bounds are midnights that name a day rather than
    /// an instant (EventKit treats them as floating). If Graph converted the
    /// midnight to UTC (the time is not 00:00), the day is recovered in the
    /// organizer's zone, `eventZone`. UNVERIFIED which form Graph sends with
    /// `Prefer: outlook.timezone="UTC"`; both are handled.
    static func startOfDay(
        from value: Graph.DateTimeTimeZone,
        eventZone: TimeZone?,
        in zone: TimeZone
    ) throws -> Date {
        guard let wall = wallClock(value.dateTime) else {
            throw GraphMappingError.invalidDateTime(value.dateTime)
        }
        var year = wall.year
        var month = wall.month
        var day = wall.day
        let isMidnight = wall.hour == 0 && wall.minute == 0 && wall.second == 0 && wall.fraction == 0
        if !isMidnight, let eventZone {
            var calendar = Calendar(identifier: .gregorian)
            calendar.timeZone = eventZone
            let parts = try calendar.dateComponents([.year, .month, .day], from: date(from: value))
            year = parts.year ?? year
            month = parts.month ?? month
            day = parts.day ?? day
        }
        let midnight = WallClock(year: year, month: month, day: day, hour: 0, minute: 0, second: 0, fraction: 0)
        guard let instant = date(from: midnight, in: zone) else {
            throw GraphMappingError.invalidDateTime(value.dateTime)
        }
        return instant
    }

    /// An `Edm.DateTimeOffset` such as `2026-10-23T16:00:00Z` or
    /// `2026-10-23T16:00:00.0000000Z`. Nil when absent or unparseable;
    /// callers fall back to `start`.
    static func offsetDate(_ value: String?) -> Date? {
        guard let value, !value.isEmpty else { return nil }
        if let date = try? Date(value, strategy: .iso8601) {
            return date
        }
        // Fractional seconds (any number of digits) with a trailing `Z`.
        guard value.hasSuffix("Z"), let wall = wallClock(String(value.dropLast())) else { return nil }
        return date(from: wall, in: TimeZone(identifier: "UTC") ?? .gmt)
    }

    /// Resolves a Graph zone name: UTC aliases, then IANA identifiers, then
    /// the Windows names in `windowsZones`. Nil when none match.
    static func timeZone(named name: String) -> TimeZone? {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        if trimmed.isEmpty || utcAliases.contains(trimmed.lowercased()) {
            return TimeZone(identifier: "UTC")
        }
        if let zone = TimeZone(identifier: trimmed) {
            return zone
        }
        return windowsZones[trimmed].flatMap(TimeZone.init(identifier:))
    }

    static func wallClock(_ text: String) -> WallClock? {
        let halves = text.split(separator: "T", omittingEmptySubsequences: false)
        guard halves.count == 2 else { return nil }
        let dateParts = halves[0].split(separator: "-", omittingEmptySubsequences: false)
        let timeAndFraction = halves[1].split(separator: ".", maxSplits: 1, omittingEmptySubsequences: false)
        let timeParts = timeAndFraction[0].split(separator: ":", omittingEmptySubsequences: false)
        guard dateParts.count == 3, timeParts.count == 2 || timeParts.count == 3,
              let year = Int(dateParts[0]), let month = Int(dateParts[1]), let day = Int(dateParts[2]),
              let hour = Int(timeParts[0]), let minute = Int(timeParts[1])
        else { return nil }
        let second = timeParts.count == 3 ? Int(timeParts[2]) : 0
        guard let second else { return nil }
        var fraction = 0.0
        if timeAndFraction.count == 2 {
            let digits = timeAndFraction[1]
            guard !digits.isEmpty, digits.allSatisfy({ $0.isASCII && $0.isNumber }), let value = Double("0.\(digits)") else {
                return nil
            }
            fraction = value
        }
        guard (1 ... 12).contains(month), (1 ... 31).contains(day), (0 ... 23).contains(hour),
              (0 ... 59).contains(minute), (0 ... 60).contains(second)
        else { return nil }
        return WallClock(
            year: year, month: month, day: day,
            hour: hour, minute: minute, second: second, fraction: fraction
        )
    }

    private static func date(from wall: WallClock, in zone: TimeZone) -> Date? {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = zone
        let components = DateComponents(
            year: wall.year, month: wall.month, day: wall.day,
            hour: wall.hour, minute: wall.minute, second: wall.second
        )
        // `isValidDate` rejects rollovers such as February 30.
        guard components.isValidDate(in: calendar), let instant = calendar.date(from: components) else {
            return nil
        }
        return instant.addingTimeInterval(wall.fraction)
    }

    /// Windows zone names Outlook commonly reports in
    /// `originalStartTimeZone`, mapped to IANA (CLDR `windowsZones.xml`,
    /// territory `001`). A short list of common business zones, not the
    /// full table; anything else maps to nil.
    static let windowsZones: [String: String] = [
        "Dateline Standard Time": "Etc/GMT+12",
        "Hawaiian Standard Time": "Pacific/Honolulu",
        "Alaskan Standard Time": "America/Anchorage",
        "Pacific Standard Time": "America/Los_Angeles",
        "US Mountain Standard Time": "America/Phoenix",
        "Mountain Standard Time": "America/Denver",
        "Central Standard Time": "America/Chicago",
        "Eastern Standard Time": "America/New_York",
        "US Eastern Standard Time": "America/Indianapolis",
        "Atlantic Standard Time": "America/Halifax",
        "Newfoundland Standard Time": "America/St_Johns",
        "SA Pacific Standard Time": "America/Bogota",
        "E. South America Standard Time": "America/Sao_Paulo",
        "GMT Standard Time": "Europe/London",
        "Greenwich Standard Time": "Atlantic/Reykjavik",
        "W. Europe Standard Time": "Europe/Berlin",
        "Romance Standard Time": "Europe/Paris",
        "Central Europe Standard Time": "Europe/Budapest",
        "Central European Standard Time": "Europe/Warsaw",
        "GTB Standard Time": "Europe/Bucharest",
        "FLE Standard Time": "Europe/Kiev",
        "Israel Standard Time": "Asia/Jerusalem",
        "Russian Standard Time": "Europe/Moscow",
        "Arabian Standard Time": "Asia/Dubai",
        "India Standard Time": "Asia/Calcutta",
        "Singapore Standard Time": "Asia/Singapore",
        "China Standard Time": "Asia/Shanghai",
        "Tokyo Standard Time": "Asia/Tokyo",
        "Korea Standard Time": "Asia/Seoul",
        "AUS Eastern Standard Time": "Australia/Sydney",
        "New Zealand Standard Time": "Pacific/Auckland",
        "South Africa Standard Time": "Africa/Johannesburg"
    ]
}
