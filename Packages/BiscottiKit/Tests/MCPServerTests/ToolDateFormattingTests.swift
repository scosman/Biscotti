import Foundation
import Testing
@testable import MCPServer

@Suite("ToolDateFormatting")
struct ToolDateFormattingTests {
    @Test("format renders UTC with second precision")
    func formatKnownTimestamp() {
        // 1_700_000_000 s since epoch == 2023-11-14T22:13:20Z.
        #expect(ToolDateFormatting.format(Date(timeIntervalSince1970: 1_700_000_000)) == "2023-11-14T22:13:20Z")
    }

    @Test("parse accepts a full timestamp and round-trips through format")
    func parseFullTimestamp() throws {
        let date = try #require(ToolDateFormatting.parse("2026-08-30T14:03:00Z"))
        #expect(ToolDateFormatting.format(date) == "2026-08-30T14:03:00Z")
    }

    @Test("parse accepts fractional seconds")
    func parseFractionalSeconds() throws {
        let withFraction = try #require(ToolDateFormatting.parse("2026-08-30T14:03:00.500Z"))
        let withoutFraction = try #require(ToolDateFormatting.parse("2026-08-30T14:03:00Z"))
        #expect(withFraction.timeIntervalSince1970 == withoutFraction.timeIntervalSince1970 + 0.5)
    }

    @Test("parse accepts an explicit UTC offset")
    func parseOffset() throws {
        let withOffset = try #require(ToolDateFormatting.parse("2026-08-30T14:03:00+02:00"))
        let utc = try #require(ToolDateFormatting.parse("2026-08-30T12:03:00Z"))
        #expect(withOffset == utc)
    }

    @Test("parse treats a bare date as local midnight")
    func parseBareDate() throws {
        let date = try #require(ToolDateFormatting.parse("2026-08-30"))
        let components = Calendar.current.dateComponents(
            [.year, .month, .day, .hour, .minute], from: date
        )
        #expect(components.year == 2026)
        #expect(components.month == 8)
        #expect(components.day == 30)
        #expect(components.hour == 0)
        #expect(components.minute == 0)
    }

    @Test("parse rejects garbage")
    func parseGarbage() {
        #expect(ToolDateFormatting.parse("not-a-date") == nil)
        #expect(ToolDateFormatting.parse("2026-13-45") == nil)
        #expect(ToolDateFormatting.parse("") == nil)
        #expect(ToolDateFormatting.parse("2026-08-30T14:03:00") == nil) // no zone
    }
}
