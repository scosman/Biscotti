import Formatting
import Foundation
import Testing

@Suite("ISO8601Formatting -- string(from:)")
struct ISO8601FormattingRenderTests {
    @Test("renders UTC with millisecond precision and Z suffix")
    func rendersExactForm() {
        // 2026-01-03T14:26:42.017Z
        let date = Date(timeIntervalSince1970: 1_767_450_402.017)
        #expect(ISO8601Formatting.string(from: date) == "2026-01-03T14:26:42.017Z")
    }

    @Test("rendered string parses back to the same instant")
    func roundTrip() throws {
        let date = Date(timeIntervalSince1970: 1_767_450_402.017)
        let parsed = try #require(ISO8601Formatting.date(from: ISO8601Formatting.string(from: date)))
        #expect(abs(parsed.timeIntervalSince1970 - date.timeIntervalSince1970) < 0.001)
    }
}

@Suite("ISO8601Formatting -- date(from:)")
struct ISO8601FormattingParseTests {
    @Test("parses ISO-8601 with fractional seconds and Z zone")
    func fractionalZ() throws {
        let parsed = try #require(ISO8601Formatting.date(from: "2026-01-03T14:26:42.017Z"))
        #expect(abs(parsed.timeIntervalSince1970 - 1_767_450_402.017) < 0.001)
    }

    @Test("parses ISO-8601 with fractional seconds and numeric offset")
    func fractionalOffset() throws {
        let parsed = try #require(ISO8601Formatting.date(from: "2026-01-03T09:26:42.017-05:00"))
        #expect(abs(parsed.timeIntervalSince1970 - 1_767_450_402.017) < 0.001)
    }

    @Test("parses ISO-8601 without fractional seconds")
    func secondPrecision() throws {
        let zoned = try #require(ISO8601Formatting.date(from: "2026-01-03T14:26:42Z"))
        #expect(zoned.timeIntervalSince1970 == 1_767_450_402)
        let offset = try #require(ISO8601Formatting.date(from: "2026-01-03T09:26:42-05:00"))
        #expect(offset.timeIntervalSince1970 == 1_767_450_402)
    }

    @Test("parses a bare calendar date as local midnight")
    func bareDateIsLocalMidnight() throws {
        let parsed = try #require(ISO8601Formatting.date(from: "2026-01-03"))
        let components = Foundation.Calendar.current.dateComponents(
            [.year, .month, .day, .hour, .minute], from: parsed
        )
        #expect(components.year == 2026)
        #expect(components.month == 1)
        #expect(components.day == 3)
        #expect(components.hour == 0)
        #expect(components.minute == 0)
    }

    @Test("parses a bare epoch-seconds integer")
    func epochSeconds() throws {
        let parsed = try #require(ISO8601Formatting.date(from: "1767450402"))
        #expect(parsed.timeIntervalSince1970 == 1_767_450_402)
    }

    @Test("parses a bare epoch-milliseconds integer")
    func epochMilliseconds() throws {
        let parsed = try #require(ISO8601Formatting.date(from: "1767450402017"))
        #expect(abs(parsed.timeIntervalSince1970 - 1_767_450_402.017) < 0.001)
    }

    @Test("the 1e11 boundary splits seconds from milliseconds")
    func epochThreshold() throws {
        // One below the threshold: seconds (year 5137).
        let asSeconds = try #require(ISO8601Formatting.date(from: "99999999999"))
        #expect(asSeconds.timeIntervalSince1970 == 99_999_999_999)
        // At the threshold: milliseconds (1973-03-03).
        let asMilliseconds = try #require(ISO8601Formatting.date(from: "100000000000"))
        #expect(asMilliseconds.timeIntervalSince1970 == 100_000_000)
    }

    @Test("trims surrounding whitespace before matching")
    func trimsWhitespace() throws {
        let parsed = try #require(ISO8601Formatting.date(from: "  2026-01-03T14:26:42Z\r\n"))
        #expect(parsed.timeIntervalSince1970 == 1_767_450_402)
    }

    @Test("rejects non-date strings")
    func rejectsGarbage() {
        #expect(ISO8601Formatting.date(from: "yesterday") == nil)
        #expect(ISO8601Formatting.date(from: "2026-13-45") == nil)
        #expect(ISO8601Formatting.date(from: "2026-01-03T14:26") == nil)
        #expect(ISO8601Formatting.date(from: "") == nil)
        #expect(ISO8601Formatting.date(from: "   ") == nil)
    }
}
