import BiscottiTestSupport
import Foundation
import Testing
@testable import AppCore
@testable import RecordingUI

// MARK: - Tests

@Suite("RecordingViewModel")
struct RecordingViewModelTests {
    @Test("isRecording reflects AppCore recording state")
    @MainActor
    func isRecordingReflectsState() async throws {
        let fix = try makeCoreFixture(testName: "RecordingUITests")
        defer { fix.cleanup() }

        let viewModel = RecordingViewModel(core: fix.core)
        #expect(viewModel.isRecording == false)

        await fix.core.startRecording()
        #expect(viewModel.isRecording == true)
    }

    @Test("elapsedText formats correctly for zero")
    @MainActor
    func elapsedTextZero() throws {
        let fix = try makeCoreFixture(testName: "RecordingUITests")
        defer { fix.cleanup() }

        let viewModel = RecordingViewModel(core: fix.core)
        #expect(viewModel.elapsedText == "00:00")
    }

    @Test("formatElapsed handles minutes and seconds")
    @MainActor
    func formatElapsedMinutesSeconds() {
        #expect(RecordingViewModel.formatElapsed(0) == "00:00")
        #expect(RecordingViewModel.formatElapsed(5) == "00:05")
        #expect(RecordingViewModel.formatElapsed(65) == "01:05")
        #expect(RecordingViewModel.formatElapsed(134) == "02:14")
    }

    @Test("formatElapsed handles hours")
    @MainActor
    func formatElapsedHours() {
        #expect(RecordingViewModel.formatElapsed(3661) == "1:01:01")
        #expect(RecordingViewModel.formatElapsed(7200) == "2:00:00")
    }

    @Test("showSystemAudioWarning is false by default")
    @MainActor
    func systemAudioWarningDefault() throws {
        let fix = try makeCoreFixture(testName: "RecordingUITests")
        defer { fix.cleanup() }

        let viewModel = RecordingViewModel(core: fix.core)
        #expect(viewModel.showSystemAudioWarning == false)
    }

    @Test("systemAudioSettingsURL returns valid URL")
    @MainActor
    func systemAudioSettingsURL() throws {
        let fix = try makeCoreFixture(testName: "RecordingUITests")
        defer { fix.cleanup() }

        let viewModel = RecordingViewModel(core: fix.core)
        #expect(viewModel.systemAudioSettingsURL.absoluteString.contains("systempreferences"))
    }

    @Test("stop delegates to AppCore")
    @MainActor
    func stopDelegates() async throws {
        let fix = try makeCoreFixture(testName: "RecordingUITests")
        defer { fix.cleanup() }

        await fix.core.startRecording()
        let viewModel = RecordingViewModel(core: fix.core)
        #expect(viewModel.isRecording == true)

        await viewModel.stop()
        #expect(viewModel.isRecording == false)
    }

    @Test("meetingTitle returns title from summaries during recording")
    @MainActor
    func meetingTitleDuringRecording() async throws {
        let fix = try makeCoreFixture(testName: "RecordingUITests")
        defer { fix.cleanup() }

        await fix.core.startRecording()
        await fix.core.reloadSummaries()

        let viewModel = RecordingViewModel(core: fix.core)
        // The meeting title is set by RecordingController.autoTitle
        #expect(viewModel.meetingTitle == "Untitled Meeting")
    }

    @Test("meetingTitle is nil when not recording")
    @MainActor
    func meetingTitleWhenNotRecording() throws {
        let fix = try makeCoreFixture(testName: "RecordingUITests")
        defer { fix.cleanup() }

        let viewModel = RecordingViewModel(core: fix.core)
        #expect(viewModel.meetingTitle == nil)
    }
}
