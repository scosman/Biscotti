import Foundation
import Testing

@testable import STTLabCore

@Suite("RunnerResume tests")
struct RunnerResumeTests {
    private let bundleID = UUID(uuidString: "12345678-1234-1234-1234-123456789ABC")!

    private func makeResult(status: RunStatus) -> AppleMeetingResult {
        AppleMeetingResult(
            bundleID: bundleID,
            meetingID: "m01",
            status: status,
            requestedLocale: "en_US",
            config: AppleConfig(),
            audioDurationSeconds: 1800
        )
    }

    @Test func noExistingResult() {
        #expect(RunnerResume.shouldRun(existing: nil, force: false) == true)
    }

    @Test func noExistingResultWithForce() {
        #expect(RunnerResume.shouldRun(existing: nil, force: true) == true)
    }

    @Test func completedNotForced() {
        let result = makeResult(status: .completed)
        #expect(RunnerResume.shouldRun(existing: result, force: false) == false)
    }

    @Test func completedForced() {
        let result = makeResult(status: .completed)
        #expect(RunnerResume.shouldRun(existing: result, force: true) == true)
    }

    @Test func failedRetries() {
        let result = makeResult(status: .failed)
        #expect(RunnerResume.shouldRun(existing: result, force: false) == true)
    }

    @Test func failedForced() {
        let result = makeResult(status: .failed)
        #expect(RunnerResume.shouldRun(existing: result, force: true) == true)
    }

    @Test func unsupportedLocaleNotForced() {
        let result = makeResult(status: .unsupportedLocale)
        #expect(RunnerResume.shouldRun(existing: result, force: false) == false)
    }

    @Test func unsupportedLocaleForced() {
        let result = makeResult(status: .unsupportedLocale)
        #expect(RunnerResume.shouldRun(existing: result, force: true) == true)
    }
}
