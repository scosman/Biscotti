import Foundation
import Testing
@testable import DesignSystem

@Suite("TimeFormatting -- relativeTimeText")
struct RelativeTimeTextTests {
    private func text(_ interval: TimeInterval) -> String {
        let now = Date()
        let future = now.addingTimeInterval(interval)
        return TimeFormatting.relativeTimeText(future, relativeTo: now)
    }

    // MARK: - "now" guard

    @Test("zero interval returns now")
    func zeroReturnsNow() {
        #expect(text(0) == "now")
    }

    @Test("negative interval returns now")
    func negativeReturnsNow() {
        #expect(text(-60) == "now")
    }

    // MARK: - Ceil behaviour (sub-minute fractions round UP)

    @Test("1 second rounds up to in 1m")
    func oneSecond() {
        #expect(text(1) == "in 1m")
    }

    @Test("60 seconds is exactly in 1m")
    func sixtySeconds() {
        #expect(text(60) == "in 1m")
    }

    @Test("61 seconds rounds up to in 2m")
    func sixtyOneSeconds() {
        #expect(text(61) == "in 2m")
    }

    @Test("119 seconds rounds up to in 2m")
    func oneNineteenSeconds() {
        #expect(text(119) == "in 2m")
    }

    @Test("120 seconds is exactly in 2m")
    func twoMinutesExact() {
        #expect(text(120) == "in 2m")
    }

    // MARK: - Exact minute values (no rounding effect)

    @Test("5 minutes")
    func fiveMinutes() {
        #expect(text(5 * 60) == "in 5m")
    }

    @Test("30 minutes")
    func thirtyMinutes() {
        #expect(text(30 * 60) == "in 30m")
    }

    @Test("59 minutes")
    func fiftyNineMinutes() {
        #expect(text(59 * 60) == "in 59m")
    }

    // MARK: - Hour boundary

    @Test("3600 seconds is exactly in 1h")
    func oneHourExact() {
        #expect(text(3600) == "in 1h")
    }

    @Test("3601 seconds rounds up to in 1h 1m")
    func oneHourPlusOneSecond() {
        #expect(text(3601) == "in 1h 1m")
    }

    @Test("2 hours exact")
    func twoHoursExact() {
        #expect(text(2 * 3600) == "in 2h")
    }

    // MARK: - Hours + minutes

    @Test("90 minutes is in 1h 30m")
    func ninetyMinutes() {
        #expect(text(90 * 60) == "in 1h 30m")
    }

    @Test("72 minutes is in 1h 12m")
    func seventyTwoMinutes() {
        #expect(text(72 * 60) == "in 1h 12m")
    }

    // MARK: - Ceil in the hour range (58m30s -> 59m, not 58m)

    @Test("58 minutes 30 seconds rounds up to in 59m")
    func fiftyEightAndAHalfMinutes() {
        #expect(text(58 * 60 + 30) == "in 59m")
    }

    @Test("59 minutes 30 seconds rounds up to in 1h")
    func fiftyNineAndAHalfMinutes() {
        #expect(text(59 * 60 + 30) == "in 1h")
    }
}
