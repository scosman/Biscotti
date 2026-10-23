import Foundation
import Testing
@testable import GraphCalendar

@Suite("GraphDateParsing")
struct GraphDateParsingTests {
    @Test("Graph's 7-digit fractions parse to the exact instant")
    func sevenDigitFraction() throws {
        let date = try GraphDateParsing.date(
            from: Graph.DateTimeTimeZone(dateTime: "2026-10-27T16:00:00.5000000", timeZone: "UTC")
        )
        #expect(try date == instant("2026-10-27T16:00:00Z").addingTimeInterval(0.5))
    }

    @Test("wall-clock forms", arguments: [
        ("2026-10-27T16:05", true), ("2026-10-27T16:05:09", true), ("2026-10-27T16:05:09.1234567", true),
        ("2026-10-27", false), ("2026-10-27T25:00:00", false), ("2026-13-01T00:00:00", false),
        ("2026-10-27T16:05:09.", false), ("2026-10-27T16:05:09.12a", false), ("garbage", false)
    ])
    func wallClockForms(text: String, parses: Bool) {
        #expect((GraphDateParsing.wallClock(text) != nil) == parses)
    }

    @Test("a missing zone is UTC; a nonexistent date throws")
    func zoneDefaultsAndInvalidDates() throws {
        let noZone = Graph.DateTimeTimeZone(dateTime: "2026-10-27T16:00:00", timeZone: nil)
        #expect(try GraphDateParsing.date(from: noZone) == instant("2026-10-27T16:00:00Z"))

        let february30 = Graph.DateTimeTimeZone(dateTime: "2026-02-30T10:00:00", timeZone: "UTC")
        #expect(throws: GraphMappingError.invalidDateTime("2026-02-30T10:00:00")) {
            try GraphDateParsing.date(from: february30)
        }
    }

    @Test("zone names: UTC aliases, IANA and Windows", arguments: [
        ("UTC", "UTC"), ("tzone://Microsoft/Utc", "UTC"), ("Coordinated Universal Time", "UTC"),
        ("Europe/London", "Europe/London"), ("Pacific Standard Time", "America/Los_Angeles"),
        ("W. Europe Standard Time", "Europe/Berlin"), ("AUS Eastern Standard Time", "Australia/Sydney")
    ])
    func zoneNames(name: String, identifier: String) throws {
        let resolved = try #require(GraphDateParsing.timeZone(named: name))
        #expect(try resolved.secondsFromGMT(for: Date()) == zone(identifier).secondsFromGMT(for: Date()))
    }

    @Test("unknown zone names resolve to nil")
    func unknownZones() {
        #expect(GraphDateParsing.timeZone(named: "Customized Time Zone") == nil)
        #expect(GraphDateParsing.timeZone(named: "Mars Standard Time") == nil)
    }

    @Test("Windows zone table entries are all real IANA zones")
    func windowsTableIsValid() {
        for (windows, iana) in GraphDateParsing.windowsZones {
            #expect(TimeZone(identifier: iana) != nil, "\(windows) → \(iana)")
        }
    }

    @Test("originalStart offsets, with and without fractions")
    func offsetDates() throws {
        let expected = try instant("2026-10-29T15:30:00Z")
        #expect(GraphDateParsing.offsetDate("2026-10-29T15:30:00Z") == expected)
        #expect(GraphDateParsing.offsetDate("2026-10-29T15:30:00.0000000Z") == expected)
        #expect(GraphDateParsing.offsetDate("") == nil)
        #expect(GraphDateParsing.offsetDate(nil) == nil)
    }
}
