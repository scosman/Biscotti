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

// MARK: - coarseRelativeTimeText

@Suite("TimeFormatting -- coarseRelativeTimeText")
struct CoarseRelativeTimeTextTests {
    private func coarse(_ interval: TimeInterval) -> String {
        let now = Date()
        let future = now.addingTimeInterval(interval)
        return TimeFormatting.coarseRelativeTimeText(future, relativeTo: now)
    }

    // MARK: - Day tier (>= 1 day)

    @Test("multi-day: 3 days shows in 3 days")
    func threeDays() {
        #expect(coarse(3 * 24 * 3600) == "in 3 days")
    }

    @Test("1 day singular: exactly 24h shows in 1 day")
    func oneDayExact() {
        #expect(coarse(24 * 3600) == "in 1 day")
    }

    @Test("1 day singular: 25h still shows in 1 day")
    func twentyFiveHours() {
        #expect(coarse(25 * 3600) == "in 1 day")
    }

    @Test("just under 2 days shows in 1 day")
    func justUnderTwoDays() {
        // 47h 59m = 2879 minutes, which is 1 day (2879/1440 = 1)
        #expect(coarse(47 * 3600 + 59 * 60) == "in 1 day")
    }

    // MARK: - Hours-only tier (> 3h and < 1 day)

    @Test("> 3h but < 1 day: 5h shows in 5h with no minutes")
    func fiveHours() {
        #expect(coarse(5 * 3600) == "in 5h")
    }

    @Test("> 3h: 5h 30m shows in 5h (minutes dropped)")
    func fiveAndHalfHours() {
        #expect(coarse(5 * 3600 + 30 * 60) == "in 5h")
    }

    @Test("> 3h: 4h shows in 4h")
    func fourHours() {
        #expect(coarse(4 * 3600) == "in 4h")
    }

    @Test("> 3h boundary: 3h 1m shows in 3h (hours-only tier)")
    func threeHoursOneMinute() {
        // 181 minutes > 180 -> hours-only tier, totalHours = 3
        #expect(coarse(3 * 3600 + 60) == "in 3h")
    }

    @Test("> 3h boundary: 3h 31m shows hours-only")
    func threeHoursThirtyOneMinutes() {
        // 211 minutes > 180 -> hours-only tier, totalHours = 3
        #expect(coarse(3 * 3600 + 31 * 60) == "in 3h")
    }

    @Test("> 3h boundary: 3h 59m shows hours-only")
    func threeHoursFiftyNineMinutes() {
        // 239 minutes > 180 -> hours-only tier, totalHours = 3
        #expect(coarse(3 * 3600 + 59 * 60) == "in 3h")
    }

    @Test("> 3h boundary: 4h 0m 1s rounds to 4h 1m in full but shows in 4h")
    func fourHoursOneSecond() {
        // totalMinutes = ceil(14401/60) = 241, totalHours = 4 -> > 3 -> "in 4h"
        #expect(coarse(4 * 3600 + 1) == "in 4h")
    }

    // MARK: - Full precision tier (<= 3h)

    @Test("<= 3h: 2h 15m shows full precision")
    func twoHoursFifteenMinutes() {
        #expect(coarse(2 * 3600 + 15 * 60) == "in 2h 15m")
    }

    @Test("<= 3h: 45m shows minutes")
    func fortyFiveMinutes() {
        #expect(coarse(45 * 60) == "in 45m")
    }

    @Test("<= 3h: exactly 3h shows in 3h")
    func threeHoursExact() {
        #expect(coarse(3 * 3600) == "in 3h")
    }

    // MARK: - Edge cases

    @Test("past returns now")
    func pastReturnsNow() {
        #expect(coarse(-60) == "now")
    }

    @Test("zero returns now")
    func zeroReturnsNow() {
        #expect(coarse(0) == "now")
    }
}

// MARK: - formatPlaybackTime

@Suite("TimeFormatting -- formatPlaybackTime")
struct FormatPlaybackTimeTests {
    @Test("formats seconds as M:SS")
    func minutesSeconds() {
        #expect(TimeFormatting.formatPlaybackTime(14) == "0:14")
        #expect(TimeFormatting.formatPlaybackTime(65) == "1:05")
        #expect(TimeFormatting.formatPlaybackTime(0) == "0:00")
    }

    @Test("formats hours as H:MM:SS")
    func hoursMinutesSeconds() {
        #expect(TimeFormatting.formatPlaybackTime(3723) == "1:02:03")
        #expect(TimeFormatting.formatPlaybackTime(7200) == "2:00:00")
    }

    @Test("negative interval clamps to zero")
    func negativeClamps() {
        #expect(TimeFormatting.formatPlaybackTime(-10) == "0:00")
    }
}
