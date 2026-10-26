import AppCore
import BiscottiTestSupport
import Foundation
import GraphAuth
import Testing
@testable import SettingsUI

// MARK: - Microsoft 365 calendar list (o365_calendar Phase 3)

@Suite("SettingsViewModel -- Microsoft 365 calendars")
@MainActor
struct SettingsMicrosoft365CalendarTests {
    @Test("signed in and synced: the account's calendars are listed")
    func listsCalendars() async throws {
        let harness = try await Microsoft365CalendarHarness(testName: "SettingsUITests")
        defer { harness.fix.cleanup() }
        let viewModel = SettingsViewModel(core: harness.fix.core)
        await viewModel.load()

        #expect(viewModel.showsCalendarList)
        #expect(viewModel.showsMicrosoft365Calendars)
        #expect(viewModel.microsoft365CalendarsCaption == nil)
        #expect(viewModel.microsoft365LastSynced == harness.sync.lastSynced)
        #expect(viewModel.calendarGroups.flatMap(\.calendars).map(\.id) == [StubGraphTenant.defaultCalendarID])
    }

    @Test("signed in before the first sync: a reading caption, no list")
    func readingCaption() async throws {
        let account = try Microsoft365Fixture(session: Microsoft365Fixture.session())
        let fix = try makeCoreFixture(microsoft365: account.controller, testName: "SettingsUITests")
        defer { fix.cleanup() }
        let viewModel = SettingsViewModel(core: fix.core)
        await account.controller.restore()

        #expect(viewModel.showsCalendarList)
        #expect(!viewModel.showsMicrosoft365Calendars)
        #expect(viewModel.microsoft365CalendarsCaption == SettingsViewModel.microsoft365ReadingCaption)
    }

    @Test("an account without calendars says so")
    func noCalendarsCaption() async throws {
        let tenant = StubGraphTenant()
        await tenant.setCalendars([])
        let harness = try await Microsoft365CalendarHarness(tenant: tenant, testName: "SettingsUITests")
        defer { harness.fix.cleanup() }
        let viewModel = SettingsViewModel(core: harness.fix.core)
        await viewModel.load()

        #expect(!viewModel.showsMicrosoft365Calendars)
        #expect(viewModel.microsoft365CalendarsCaption == SettingsViewModel.microsoft365NoCalendarsCaption)
    }

    @Test("signed out with a registration: no calendar list, even with Apple Calendar access")
    func signedOutHidesList() throws {
        let account = try Microsoft365Fixture()
        let fix = try makeCoreFixture(calendarAuthStatus: .authorized, microsoft365: account.controller, testName: "SettingsUITests")
        defer { fix.cleanup() }
        let viewModel = SettingsViewModel(core: fix.core)

        #expect(!viewModel.showsCalendarList)
        #expect(viewModel.microsoft365CalendarsCaption == nil)
    }

    @Test("a failed calendar read shows under the row")
    func syncErrorShown() async throws {
        let tenant = StubGraphTenant()
        let harness = try await Microsoft365CalendarHarness(tenant: tenant, testName: "SettingsUITests")
        defer { harness.fix.cleanup() }
        let viewModel = SettingsViewModel(core: harness.fix.core)

        await tenant.setOffline(true)
        await harness.sync.refresh()

        #expect(viewModel.microsoft365Error == "Couldn't reach Microsoft 365. Showing meetings from the last sync.")
    }

    @Test("the last-sync caption")
    func syncedCaption() {
        let now = Date()
        #expect(Microsoft365AccountRow.syncedCaption(now.addingTimeInterval(-30), now: now) == "Synced just now")
        let older = Microsoft365AccountRow.syncedCaption(now.addingTimeInterval(-300), now: now)
        #expect(older.hasPrefix("Synced "))
        #expect(older != "Synced just now")
    }
}
