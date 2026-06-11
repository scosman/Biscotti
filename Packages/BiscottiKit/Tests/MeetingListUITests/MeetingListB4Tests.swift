import BiscottiTestSupport
import DataStore
import DesignSystem
import Foundation
import Testing
@testable import AppCore
@testable import MeetingListUI

// MARK: - Second-line text tests

@Suite("MeetingListViewModel -- secondLineText")
struct MeetingListSecondLineTests {
    @Test("secondLineText shows date only when no duration")
    @MainActor
    func secondLineNoDuration() {
        let date = Date(timeIntervalSince1970: 1_781_193_600) // Jun 9, 2026
        let summary = MeetingSummary(
            id: UUID(),
            title: "Test",
            date: date,
            hasTranscript: false,
            recordingDuration: nil
        )
        let text = MeetingListViewModel.secondLineText(for: summary)
        #expect(text == TimeFormatting.shortDate(date))
    }

    @Test("secondLineText shows date and duration when duration present")
    @MainActor
    func secondLineWithDuration() {
        let date = Date(timeIntervalSince1970: 1_781_193_600)
        let summary = MeetingSummary(
            id: UUID(),
            title: "Test",
            date: date,
            hasTranscript: false,
            recordingDuration: 34 * 60 // 34 minutes
        )
        let text = MeetingListViewModel.secondLineText(for: summary)
        let expected = "\(TimeFormatting.shortDate(date)) \u{00B7} 34m"
        #expect(text == expected)
    }

    @Test("secondLineText shows date only when duration is zero")
    @MainActor
    func secondLineZeroDuration() {
        let date = Date(timeIntervalSince1970: 1_781_193_600)
        let summary = MeetingSummary(
            id: UUID(),
            title: "Test",
            date: date,
            hasTranscript: false,
            recordingDuration: 0
        )
        let text = MeetingListViewModel.secondLineText(for: summary)
        #expect(text == TimeFormatting.shortDate(date))
    }

    @Test("secondLineText formats hours and minutes")
    @MainActor
    func secondLineLongDuration() {
        let date = Date(timeIntervalSince1970: 1_781_193_600)
        let summary = MeetingSummary(
            id: UUID(),
            title: "Test",
            date: date,
            hasTranscript: false,
            recordingDuration: 72 * 60 // 1h 12m
        )
        let text = MeetingListViewModel.secondLineText(for: summary)
        let expected = "\(TimeFormatting.shortDate(date)) \u{00B7} 1h 12m"
        #expect(text == expected)
    }
}

// MARK: - Duration formatting tests

@Suite("TimeFormatting -- compactDuration")
struct CompactDurationTests {
    @Test("less than 1 minute shows <1m")
    func lessThanOneMinute() {
        #expect(TimeFormatting.compactDuration(30) == "<1m")
    }

    @Test("exact minutes")
    func exactMinutes() {
        #expect(TimeFormatting.compactDuration(34 * 60) == "34m")
    }

    @Test("hours and minutes")
    func hoursAndMinutes() {
        #expect(TimeFormatting.compactDuration(72 * 60) == "1h 12m")
    }

    @Test("exact hours")
    func exactHours() {
        #expect(TimeFormatting.compactDuration(2 * 3600) == "2h")
    }

    @Test("zero seconds shows <1m")
    func zeroSeconds() {
        #expect(TimeFormatting.compactDuration(0) == "<1m")
    }
}

// MARK: - Duration persisted via summary DTO

@Suite("MeetingSummary -- recordingDuration round-trip")
struct MeetingSummaryDurationTests {
    @Test("meetingSummaries includes recordingDuration from Meeting model")
    @MainActor
    func durationSurfacedInSummary() async throws {
        let fix = try makeCoreFixture(testName: "MeetingListB4Tests")
        defer { fix.cleanup() }

        let meetingID = try await fix.store.createMeeting(title: "Recorded")
        try await fix.store.setRecordingDuration(1845, for: meetingID) // 30m 45s

        let summaries = try await fix.store.meetingSummaries(limit: 10)
        let summary = try #require(summaries.first { $0.id == meetingID })
        #expect(summary.recordingDuration == 1845)
    }

    @Test("meetingSummaries returns nil duration when not set")
    @MainActor
    func durationNilWhenNotSet() async throws {
        let fix = try makeCoreFixture(testName: "MeetingListB4Tests")
        defer { fix.cleanup() }

        let meetingID = try await fix.store.createMeeting(title: "No Recording")

        let summaries = try await fix.store.meetingSummaries(limit: 10)
        let summary = try #require(summaries.first { $0.id == meetingID })
        #expect(summary.recordingDuration == nil)
    }
}
