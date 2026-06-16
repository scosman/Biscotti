import DataStore
import Foundation
import Testing

@Suite("MenuBarLeadTime")
struct MenuBarLeadTimeTests {
    // MARK: - Init from seconds

    @Test("init from known seconds returns matching case")
    func initKnownSeconds() {
        #expect(MenuBarLeadTime(seconds: 0) == .never)
        #expect(MenuBarLeadTime(seconds: 300) == .fiveMinutes)
        #expect(MenuBarLeadTime(seconds: 600) == .tenMinutes)
        #expect(MenuBarLeadTime(seconds: 900) == .fifteenMinutes)
        #expect(MenuBarLeadTime(seconds: 1800) == .thirtyMinutes)
        #expect(MenuBarLeadTime(seconds: 3600) == .oneHour)
        #expect(MenuBarLeadTime(seconds: 7200) == .twoHours)
        #expect(MenuBarLeadTime(seconds: 21600) == .sixHours)
        #expect(MenuBarLeadTime(seconds: 43200) == .twelveHours)
        #expect(MenuBarLeadTime(seconds: 86400) == .twentyFourHours)
    }

    @Test("init from unknown seconds falls back to oneHour")
    func initUnknownSeconds() {
        #expect(MenuBarLeadTime(seconds: 42) == .oneHour)
        #expect(MenuBarLeadTime(seconds: -1) == .oneHour)
        #expect(MenuBarLeadTime(seconds: 999_999) == .oneHour)
    }

    // MARK: - Display text

    @Test("all cases have non-empty display text")
    func allCasesHaveDisplayText() {
        for option in MenuBarLeadTime.allCases {
            #expect(!option.displayText.isEmpty)
        }
    }

    @Test("default is oneHour (3600 seconds)")
    func defaultIsOneHour() {
        #expect(MenuBarLeadTime.oneHour.rawValue == 3600)
    }

    // MARK: - shouldShowDetailedText

    @Test("never returns false regardless of timing")
    func neverAlwaysFalse() {
        let now = Date()
        let meetingStart = now.addingTimeInterval(60) // 1 min from now
        #expect(
            MenuBarLeadTime.never.shouldShowDetailedText(
                meetingStart: meetingStart, now: now
            ) == false
        )
    }

    @Test("shows text when within lead time before meeting")
    func withinLeadTimeBeforeMeeting() {
        let now = Date()
        // Meeting in 30 min, lead time is 1 hour
        let meetingStart = now.addingTimeInterval(30 * 60)
        #expect(
            MenuBarLeadTime.oneHour.shouldShowDetailedText(
                meetingStart: meetingStart, now: now
            ) == true
        )
    }

    @Test("hides text when outside lead time before meeting")
    func outsideLeadTimeBeforeMeeting() {
        let now = Date()
        // Meeting in 2 hours, lead time is 1 hour
        let meetingStart = now.addingTimeInterval(2 * 3600)
        #expect(
            MenuBarLeadTime.oneHour.shouldShowDetailedText(
                meetingStart: meetingStart, now: now
            ) == false
        )
    }

    @Test("shows text at exact lead time boundary")
    func exactLeadTimeBoundary() {
        let now = Date()
        // Meeting in exactly 1 hour, lead time is 1 hour
        let meetingStart = now.addingTimeInterval(3600)
        #expect(
            MenuBarLeadTime.oneHour.shouldShowDetailedText(
                meetingStart: meetingStart, now: now
            ) == true
        )
    }

    @Test("shows text within 5 min after meeting start (grace period)")
    func withinGracePeriodAfterStart() {
        let now = Date()
        // Meeting started 3 min ago
        let meetingStart = now.addingTimeInterval(-3 * 60)
        #expect(
            MenuBarLeadTime.oneHour.shouldShowDetailedText(
                meetingStart: meetingStart, now: now
            ) == true
        )
    }

    @Test("shows text at exact grace period boundary (5 min after start)")
    func exactGracePeriodBoundary() {
        let now = Date()
        // Meeting started exactly 5 min ago
        let meetingStart = now.addingTimeInterval(-5 * 60)
        #expect(
            MenuBarLeadTime.oneHour.shouldShowDetailedText(
                meetingStart: meetingStart, now: now
            ) == true
        )
    }

    @Test("hides text after grace period expires (>5 min after start)")
    func afterGracePeriodExpires() {
        let now = Date()
        // Meeting started 6 min ago
        let meetingStart = now.addingTimeInterval(-6 * 60)
        #expect(
            MenuBarLeadTime.oneHour.shouldShowDetailedText(
                meetingStart: meetingStart, now: now
            ) == false
        )
    }

    @Test("5 min lead time: shows 3 min before, hides 10 min before")
    func fiveMinuteLeadTime() {
        let now = Date()
        let meetingStart = now.addingTimeInterval(3 * 60) // 3 min from now
        #expect(
            MenuBarLeadTime.fiveMinutes.shouldShowDetailedText(
                meetingStart: meetingStart, now: now
            ) == true
        )

        let meetingStartFar = now.addingTimeInterval(10 * 60) // 10 min from now
        #expect(
            MenuBarLeadTime.fiveMinutes.shouldShowDetailedText(
                meetingStart: meetingStartFar, now: now
            ) == false
        )
    }

    @Test("24h lead time: shows 23h before meeting")
    func twentyFourHourLeadTime() {
        let now = Date()
        let meetingStart = now.addingTimeInterval(23 * 3600) // 23h from now
        #expect(
            MenuBarLeadTime.twentyFourHours.shouldShowDetailedText(
                meetingStart: meetingStart, now: now
            ) == true
        )
    }

    @Test("grace period applies to all non-never options")
    func gracePeriodAllOptions() {
        let now = Date()
        // Meeting started 3 min ago
        let meetingStart = now.addingTimeInterval(-3 * 60)

        for option in MenuBarLeadTime.allCases where option != .never {
            #expect(
                option.shouldShowDetailedText(
                    meetingStart: meetingStart, now: now
                ) == true,
                "\(option) should show text within grace period"
            )
        }
    }

    @Test("all cases in expected count")
    func allCasesCount() {
        #expect(MenuBarLeadTime.allCases.count == 10)
    }
}
