import AppCore
import BiscottiTestSupport
import Foundation
import GraphAuth
import Testing
@testable import SettingsUI

// MARK: - Microsoft 365 account row

@Suite("SettingsViewModel -- Microsoft 365")
@MainActor
struct SettingsMicrosoft365Tests {
    @Test("without a registration the row reports not configured")
    func notConfigured() throws {
        let fix = try makeCoreFixture()
        defer { fix.cleanup() }
        let viewModel = SettingsViewModel(core: fix.core)
        #expect(viewModel.microsoft365State == .notConfigured(.missingClientID))
        #expect(viewModel.microsoft365Error == nil)
    }

    @Test("the row forwards the controller's restored state")
    func forwardsState() async throws {
        let account = try Microsoft365Fixture(session: Microsoft365Fixture.session(refreshToken: nil))
        let fix = try makeCoreFixture(microsoft365: account.controller)
        defer { fix.cleanup() }
        let viewModel = SettingsViewModel(core: fix.core)

        #expect(viewModel.microsoft365State == .signedOut)
        await account.controller.restore()
        #expect(viewModel.microsoft365State == .needsReconnect(Microsoft365Fixture.account))
    }

    @Test("Connect opens the browser; a declined consent shows the error")
    func connectError() async throws {
        let account = try Microsoft365Fixture()
        account.browser.result = try .success(
            #require(URL(string: "msauth.com.synderys.biscotti://auth?error=access_denied&error_description=AADSTS65004%3a+User+declined"))
        )
        let fix = try makeCoreFixture(microsoft365: account.controller)
        defer { fix.cleanup() }
        let viewModel = SettingsViewModel(core: fix.core)

        await viewModel.connectMicrosoft365()
        #expect(account.browser.openedURLs.count == 1)
        #expect(viewModel.microsoft365State == .signedOut)
        #expect(viewModel.microsoft365Error == "Microsoft sign-in didn't complete: AADSTS65004: User declined")

        viewModel.cancelMicrosoft365SignIn()
        #expect(account.browser.cancelCount == 1)
    }

    @Test("Disconnect forgets the account and its saved session")
    func disconnect() async throws {
        let account = try Microsoft365Fixture(session: Microsoft365Fixture.session())
        let fix = try makeCoreFixture(microsoft365: account.controller)
        defer { fix.cleanup() }
        let viewModel = SettingsViewModel(core: fix.core)
        await account.controller.restore()
        #expect(viewModel.microsoft365State == .signedIn(Microsoft365Fixture.account))

        await viewModel.disconnectMicrosoft365()
        #expect(viewModel.microsoft365State == .signedOut)
        #expect(account.store.stored == nil)
    }

    @Test("the Apple Calendar permission row shows only without a registration")
    func appleCalendarPermissionRow() throws {
        let unconfigured = try makeCoreFixture()
        defer { unconfigured.cleanup() }
        #expect(SettingsViewModel(core: unconfigured.core).showsAppleCalendarPermission)

        let account = try Microsoft365Fixture()
        let configured = try makeCoreFixture(microsoft365: account.controller)
        defer { configured.cleanup() }
        #expect(!SettingsViewModel(core: configured.core).showsAppleCalendarPermission)
    }

    @Test("with a registration, calendar notifications follow the Microsoft 365 account")
    func calendarNotificationsFollowAccount() async throws {
        let account = try Microsoft365Fixture(session: Microsoft365Fixture.session())
        let fix = try makeCoreFixture(microsoft365: account.controller)
        defer { fix.cleanup() }
        let viewModel = SettingsViewModel(core: fix.core)
        fix.permissions.noteCalendar(.authorized)

        // Apple Calendar access alone doesn't count.
        #expect(viewModel.calendarNotificationsDisabled)
        await account.controller.restore()
        #expect(!viewModel.calendarNotificationsDisabled)

        fix.permissions.noteCalendar(.denied)
        #expect(!viewModel.calendarNotificationsDisabled)
        await viewModel.disconnectMicrosoft365()
        #expect(viewModel.calendarNotificationsDisabled)
    }

    @Test("row captions name the account")
    func captions() {
        #expect(Microsoft365AccountRow.reconnectCaption(Microsoft365Fixture.account).contains("jane@synderys.com"))
        #expect(Microsoft365AccountRow.disconnectMessage(Microsoft365Fixture.account).contains(" for jane@synderys.com."))
        #expect(!Microsoft365AccountRow.disconnectMessage(nil).contains(" for "))
    }
}
