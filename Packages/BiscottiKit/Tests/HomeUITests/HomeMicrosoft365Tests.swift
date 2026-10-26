import BiscottiTestSupport
import Foundation
import GraphAuth
import Testing
@testable import HomeUI

// MARK: - Microsoft 365 reconnect banner

@Suite("HomeViewModel -- Microsoft 365")
@MainActor
struct HomeMicrosoft365Tests {
    @Test("no banner without a registration")
    func notConfigured() throws {
        let fix = try makeCoreFixture(testName: "HomeUITests")
        defer { fix.cleanup() }
        #expect(!HomeViewModel(core: fix.core).microsoft365NeedsReconnect)
    }

    @Test("the banner shows only while the account needs reconnecting")
    func bannerFollowsState() async throws {
        let account = try Microsoft365Fixture(session: Microsoft365Fixture.session(refreshToken: nil))
        let fix = try makeCoreFixture(microsoft365: account.controller, testName: "HomeUITests")
        defer { fix.cleanup() }
        let viewModel = HomeViewModel(core: fix.core)

        #expect(!viewModel.microsoft365NeedsReconnect)
        await account.controller.restore()
        #expect(viewModel.microsoft365NeedsReconnect)

        await account.controller.signOut()
        #expect(!viewModel.microsoft365NeedsReconnect)
    }

    @Test("Reconnect opens the sign-in pre-filled with the account")
    func reconnect() async throws {
        let account = try Microsoft365Fixture(session: Microsoft365Fixture.session(refreshToken: nil))
        let fix = try makeCoreFixture(microsoft365: account.controller, testName: "HomeUITests")
        defer { fix.cleanup() }
        let viewModel = HomeViewModel(core: fix.core)
        await account.controller.restore()

        await viewModel.connectMicrosoft365()
        let url = try #require(account.browser.openedURLs.first)
        let hint = URLComponents(url: url, resolvingAgainstBaseURL: false)?
            .queryItems?.first { $0.name == "login_hint" }?.value
        #expect(hint == "jane@synderys.com")
        // The scripted browser cancels, so the banner stays.
        #expect(viewModel.microsoft365NeedsReconnect)
    }

    // MARK: - Upcoming card (Microsoft 365 replaces Apple Calendar)

    @Test("configured and signed out: Connect Microsoft 365, never the Apple Calendar card")
    func connectCardReplacesAppleCalendar() async throws {
        let account = try Microsoft365Fixture()
        let fix = try makeCoreFixture(
            calendarAuthStatus: .notDetermined,
            microsoft365: account.controller,
            testName: "HomeUITests"
        )
        defer { fix.cleanup() }
        let viewModel = HomeViewModel(core: fix.core)
        await account.controller.restore()

        #expect(viewModel.showConnectMicrosoft365)
        #expect(!viewModel.showConnectCalendar)
        #expect(!viewModel.showNoUpcoming)
        #expect(!viewModel.microsoft365SigningIn)
    }

    @Test("Connect opens the sign-in without a pre-filled account")
    func connectFromCard() async throws {
        let account = try Microsoft365Fixture()
        let fix = try makeCoreFixture(microsoft365: account.controller, testName: "HomeUITests")
        defer { fix.cleanup() }
        let viewModel = HomeViewModel(core: fix.core)

        await viewModel.connectMicrosoft365()
        let url = try #require(account.browser.openedURLs.first)
        let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        #expect(!items.contains { $0.name == "login_hint" })
        // The scripted browser cancels, so the card stays.
        #expect(viewModel.showConnectMicrosoft365)
    }

    @Test("signed in with no events: No meetings coming up, even without Apple Calendar access")
    func signedInShowsNoUpcoming() async throws {
        let account = try Microsoft365Fixture(session: Microsoft365Fixture.session())
        let fix = try makeCoreFixture(
            calendarAuthStatus: .denied,
            microsoft365: account.controller,
            testName: "HomeUITests"
        )
        defer { fix.cleanup() }
        let viewModel = HomeViewModel(core: fix.core)
        await account.controller.restore()

        #expect(viewModel.showNoUpcoming)
        #expect(!viewModel.showConnectMicrosoft365)
        #expect(!viewModel.showConnectCalendar)
    }

    @Test("needs reconnect: the banner, and no Connect or Apple Calendar card")
    func reconnectShowsBannerOnly() async throws {
        let account = try Microsoft365Fixture(session: Microsoft365Fixture.session(refreshToken: nil))
        let fix = try makeCoreFixture(
            calendarAuthStatus: .notDetermined,
            microsoft365: account.controller,
            testName: "HomeUITests"
        )
        defer { fix.cleanup() }
        let viewModel = HomeViewModel(core: fix.core)
        await account.controller.restore()

        #expect(viewModel.microsoft365NeedsReconnect)
        #expect(!viewModel.showConnectMicrosoft365)
        #expect(!viewModel.showConnectCalendar)
        #expect(!viewModel.showNoUpcoming)
    }

    @Test("without a registration the Apple Calendar card still shows")
    func notConfiguredKeepsAppleCalendar() throws {
        let fix = try makeCoreFixture(calendarAuthStatus: .notDetermined, testName: "HomeUITests")
        defer { fix.cleanup() }
        let viewModel = HomeViewModel(core: fix.core)

        #expect(viewModel.showConnectCalendar)
        #expect(!viewModel.showConnectMicrosoft365)
    }
}
