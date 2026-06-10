import BiscottiTestSupport
import Foundation
import Testing
@testable import AppCore
@testable import AppShellUI

// MARK: - Tests

@Suite("AppShellViewModel -- sidebar state")
struct AppShellSidebarTests {
    @Test("recordButtonDisabled is false when not recording")
    @MainActor
    func recordButtonEnabledWhenIdle() throws {
        let fix = try makeCoreFixture(testName: "AppShellUITests")
        defer { fix.cleanup() }

        let viewModel = AppShellViewModel(core: fix.core)
        #expect(viewModel.recordButtonDisabled == false)
    }

    @Test("recordButtonDisabled is true when recording")
    @MainActor
    func recordButtonDisabledWhenRecording() async throws {
        let fix = try makeCoreFixture(testName: "AppShellUITests")
        defer { fix.cleanup() }

        await fix.core.startRecording()

        let viewModel = AppShellViewModel(core: fix.core)
        #expect(viewModel.recordButtonDisabled == true)
    }

    @Test("showRecordingIndicator is false when not recording")
    @MainActor
    func recordingIndicatorHiddenWhenIdle() throws {
        let fix = try makeCoreFixture(testName: "AppShellUITests")
        defer { fix.cleanup() }

        let viewModel = AppShellViewModel(core: fix.core)
        #expect(viewModel.showRecordingIndicator == false)
    }

    @Test("showRecordingIndicator is true when recording")
    @MainActor
    func recordingIndicatorShownWhenRecording() async throws {
        let fix = try makeCoreFixture(testName: "AppShellUITests")
        defer { fix.cleanup() }

        await fix.core.startRecording()

        let viewModel = AppShellViewModel(core: fix.core)
        #expect(viewModel.showRecordingIndicator == true)
    }

    @Test("recordingElapsedText formats correctly at zero")
    @MainActor
    func recordingElapsedTextZero() throws {
        let fix = try makeCoreFixture(testName: "AppShellUITests")
        defer { fix.cleanup() }

        let viewModel = AppShellViewModel(core: fix.core)
        #expect(viewModel.recordingElapsedText == "0:00")
    }
}

@Suite("AppShellViewModel -- routing")
struct AppShellRoutingTests {
    @Test("route is .home initially")
    @MainActor
    func routeHomeInitially() throws {
        let fix = try makeCoreFixture(testName: "AppShellUITests")
        defer { fix.cleanup() }

        let viewModel = AppShellViewModel(core: fix.core)
        #expect(viewModel.route == .home)
    }

    @Test("route is .recording after startRecording")
    @MainActor
    func routeRecordingAfterStart() async throws {
        let fix = try makeCoreFixture(testName: "AppShellUITests")
        defer { fix.cleanup() }

        let viewModel = AppShellViewModel(core: fix.core)
        await viewModel.startRecording()
        #expect(viewModel.route == .recording)
    }

    @Test("route is .meeting after selecting a meeting")
    @MainActor
    func routeMeetingAfterSelect() throws {
        let fix = try makeCoreFixture(testName: "AppShellUITests")
        defer { fix.cleanup() }

        let viewModel = AppShellViewModel(core: fix.core)
        let meetingID = UUID()
        fix.core.select(meetingID)
        #expect(viewModel.route == .meeting(meetingID))
    }

    @Test("showRecording navigates back to recording screen")
    @MainActor
    func showRecordingNavigatesBack() async throws {
        let fix = try makeCoreFixture(testName: "AppShellUITests")
        defer { fix.cleanup() }

        let viewModel = AppShellViewModel(core: fix.core)
        await viewModel.startRecording()
        #expect(viewModel.route == .recording)

        // User selects a past meeting during recording
        fix.core.select(UUID())
        #expect(viewModel.route != .recording)

        // Tap recording indicator to go back
        viewModel.showRecording()
        #expect(viewModel.route == .recording)
    }

    @Test("showRecording is a no-op when not recording")
    @MainActor
    func showRecordingNoOpWhenIdle() throws {
        let fix = try makeCoreFixture(testName: "AppShellUITests")
        defer { fix.cleanup() }

        let viewModel = AppShellViewModel(core: fix.core)
        viewModel.showRecording()
        #expect(viewModel.route == .home)
    }

    @Test("appCore exposes the underlying core")
    @MainActor
    func appCoreAccessible() throws {
        let fix = try makeCoreFixture(testName: "AppShellUITests")
        defer { fix.cleanup() }

        let viewModel = AppShellViewModel(core: fix.core)
        // Verify it's the same instance by checking route identity
        let meetingID = UUID()
        fix.core.select(meetingID)
        #expect(viewModel.appCore.route == .meeting(meetingID))
    }
}

@Suite("AppShellViewModel -- child view model stability")
struct AppShellChildVMTests {
    @Test("child view models are stable across accesses")
    @MainActor
    func childViewModelsStable() throws {
        let fix = try makeCoreFixture(testName: "AppShellUITests")
        defer { fix.cleanup() }

        let viewModel = AppShellViewModel(core: fix.core)

        // MeetingListViewModel should be the same instance across accesses
        let listVM1 = viewModel.meetingListViewModel
        let listVM2 = viewModel.meetingListViewModel
        #expect(listVM1 === listVM2)

        // RecordingViewModel should be the same instance across accesses
        let recordingVM1 = viewModel.recordingViewModel
        let recordingVM2 = viewModel.recordingViewModel
        #expect(recordingVM1 === recordingVM2)
    }

    @Test("meetingDetailViewModel returns stable instance for same meeting ID")
    @MainActor
    func meetingDetailVMStableForSameID() throws {
        let fix = try makeCoreFixture(testName: "AppShellUITests")
        defer { fix.cleanup() }

        let viewModel = AppShellViewModel(core: fix.core)
        let meetingID = UUID()

        let detailVM1 = viewModel.meetingDetailViewModel(for: meetingID)
        let detailVM2 = viewModel.meetingDetailViewModel(for: meetingID)
        #expect(detailVM1 === detailVM2)
    }

    @Test("meetingDetailViewModel returns new instance for different meeting ID")
    @MainActor
    func meetingDetailVMNewForDifferentID() throws {
        let fix = try makeCoreFixture(testName: "AppShellUITests")
        defer { fix.cleanup() }

        let viewModel = AppShellViewModel(core: fix.core)
        let id1 = UUID()
        let id2 = UUID()

        let detailVM1 = viewModel.meetingDetailViewModel(for: id1)
        let detailVM2 = viewModel.meetingDetailViewModel(for: id2)
        #expect(detailVM1 !== detailVM2)
    }
}
