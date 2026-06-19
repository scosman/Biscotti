import BiscottiTestSupport
import Testing
import UserNotifications
@testable import SettingsUI

@Suite("SettingsViewModel -- stay-visible row")
@MainActor
struct SettingsStayVisibleTests {
    @Test("showStayVisibleRow defaults to false before load")
    func defaultsToFalse() throws {
        let fix = try makeCoreFixture()
        defer { fix.cleanup() }
        let viewModel = SettingsViewModel(core: fix.core)
        #expect(viewModel.showStayVisibleRow == false)
    }

    @Test("load sets showStayVisibleRow true when alert style is banner")
    func loadShowsRowForBanner() async throws {
        let fix = try makeCoreFixture()
        defer { fix.cleanup() }
        fix.fakeNotificationCenter.backing.scriptedAlertStyle = .banner
        let viewModel = SettingsViewModel(core: fix.core)
        await viewModel.load()
        #expect(viewModel.showStayVisibleRow == true)
    }

    @Test("load sets showStayVisibleRow false when alert style is alert")
    func loadHidesRowForAlert() async throws {
        let fix = try makeCoreFixture()
        defer { fix.cleanup() }
        fix.fakeNotificationCenter.backing.scriptedAlertStyle = .alert
        let viewModel = SettingsViewModel(core: fix.core)
        await viewModel.load()
        #expect(viewModel.showStayVisibleRow == false)
    }

    @Test("load sets showStayVisibleRow false when alert style is none")
    func loadHidesRowForNone() async throws {
        let fix = try makeCoreFixture()
        defer { fix.cleanup() }
        fix.fakeNotificationCenter.backing.scriptedAlertStyle = .none
        let viewModel = SettingsViewModel(core: fix.core)
        await viewModel.load()
        #expect(viewModel.showStayVisibleRow == false)
    }

    @Test("refreshAlertStyle updates showStayVisibleRow")
    func refreshUpdatesRow() async throws {
        let fix = try makeCoreFixture()
        defer { fix.cleanup() }
        fix.fakeNotificationCenter.backing.scriptedAlertStyle = .banner
        let viewModel = SettingsViewModel(core: fix.core)
        await viewModel.load()
        #expect(viewModel.showStayVisibleRow == true)

        // Simulate user switching to Alerts in System Settings
        fix.fakeNotificationCenter.backing.scriptedAlertStyle = .alert
        await viewModel.refreshAlertStyle()
        #expect(viewModel.showStayVisibleRow == false)

        // Simulate switching back to Banners
        fix.fakeNotificationCenter.backing.scriptedAlertStyle = .banner
        await viewModel.refreshAlertStyle()
        #expect(viewModel.showStayVisibleRow == true)
    }
}
