import Foundation
import Testing
@testable import Calendar

@Suite("CalendarDeepLink -- calendarAppURL")
struct CalendarDeepLinkTests {
    @Test("Uses ical ekevent URL when event identifier is provided")
    func usesEkeventURL() {
        let url = CalendarDeepLink.calendarAppURL(
            eventIdentifier: "ABC123",
            startDate: Date(timeIntervalSince1970: 1_700_000_000)
        )
        #expect(url != nil)
        #expect(url?.scheme == "ical")
        #expect(url?.absoluteString.contains("ekevent/ABC123") == true)
        #expect(url?.absoluteString.contains("method=show") == true)
        #expect(url?.absoluteString.contains("options=more") == true)
    }

    @Test("Falls back to date-based URL when event identifier is nil")
    func fallsBackToDateURL() {
        let date = Date(timeIntervalSinceReferenceDate: 803_397_600)
        let url = CalendarDeepLink.calendarAppURL(
            eventIdentifier: nil,
            startDate: date
        )
        #expect(url != nil)
        #expect(url?.scheme == "ical")
        #expect(url?.absoluteString == "ical://803397600")
    }

    @Test("Falls back to date-based URL when event identifier is empty")
    func fallsBackWhenIdentifierEmpty() {
        let date = Date(timeIntervalSinceReferenceDate: 803_397_600)
        let url = CalendarDeepLink.calendarAppURL(
            eventIdentifier: "",
            startDate: date
        )
        #expect(url != nil)
        #expect(url?.absoluteString == "ical://803397600")
    }

    @Test("Date-based URL uses integer epoch (no fractional .0)")
    func integerEpochNoFraction() throws {
        // Use a date that has fractional seconds
        let date = Date(timeIntervalSinceReferenceDate: 803_397_600.75)
        let url = CalendarDeepLink.calendarAppURL(
            eventIdentifier: nil,
            startDate: date
        )
        #expect(url != nil)
        let urlString = try #require(url?.absoluteString)
        // Must not contain a decimal point -- integer epoch only
        #expect(!urlString.contains("."))
        #expect(urlString == "ical://803397600")
    }

    @Test("Returns ical:// last resort when both inputs are nil")
    func lastResortJustOpensCalendar() {
        let url = CalendarDeepLink.calendarAppURL(
            eventIdentifier: nil,
            startDate: nil
        )
        #expect(url != nil)
        #expect(url?.absoluteString == "ical://")
    }

    @Test("Prefers event identifier over date when both are provided")
    func prefersIdentifierOverDate() throws {
        let url = CalendarDeepLink.calendarAppURL(
            eventIdentifier: "EVT-42",
            startDate: Date(timeIntervalSinceReferenceDate: 100_000)
        )
        #expect(url != nil)
        #expect(url?.absoluteString.contains("ekevent/EVT-42") == true)
        // Should NOT contain the timestamp fallback
        #expect(try !#require(url?.absoluteString.contains("100000")))
    }
}
