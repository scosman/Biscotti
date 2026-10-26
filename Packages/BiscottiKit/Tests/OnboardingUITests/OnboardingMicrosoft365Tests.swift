import BiscottiTestSupport
import Calendar
import GraphAuth
import Testing
@testable import OnboardingUI

// MARK: - Microsoft 365 replaces the Calendar permission (Synderys fork)

@Suite("OnboardingViewModel -- Microsoft 365")
@MainActor
struct OnboardingMicrosoft365Tests {
    @Test("without a registration the Calendar permission stays")
    func notConfigured() throws {
        let fixture = try makeCoreFixture(calendarAuthStatus: .notDetermined)
        defer { fixture.cleanup() }
        let model = OnboardingViewModel(core: fixture.core)

        #expect(!model.usesMicrosoft365)
        #expect(!model.calendarGranted)
    }

    @Test("with a registration, the calendar is granted by signing in, not Apple Calendar")
    func grantedFollowsSignIn() async throws {
        let account = try Microsoft365Fixture(session: Microsoft365Fixture.session())
        let fixture = try makeCoreFixture(calendarAuthStatus: .authorized, microsoft365: account.controller)
        defer { fixture.cleanup() }
        let model = OnboardingViewModel(core: fixture.core)
        await model.advance() // welcome -> permissions

        #expect(model.usesMicrosoft365)
        #expect(!model.calendarGranted)
        await account.controller.restore()
        #expect(model.calendarGranted)
    }

    @Test("signed in: the calendar step lists the account's calendars")
    func calendarStepListsGraphCalendars() async throws {
        let harness = try await Microsoft365CalendarHarness(testName: "OnboardingUITests")
        defer { harness.fix.cleanup() }
        let model = OnboardingViewModel(core: harness.fix.core)

        await model.advance() // welcome -> permissions
        await model.advance()

        #expect(model.currentStep == .calendarSelection)
        #expect(model.calendarGroups.flatMap(\.calendars).map(\.id) == [StubGraphTenant.defaultCalendarID])
    }

    @Test("an account without calendars gets its own empty state")
    func noCalendars() async throws {
        let tenant = StubGraphTenant()
        await tenant.setCalendars([])
        let harness = try await Microsoft365CalendarHarness(tenant: tenant, testName: "OnboardingUITests")
        defer { harness.fix.cleanup() }
        let model = OnboardingViewModel(core: harness.fix.core)

        await model.advance() // welcome -> permissions
        await model.advance()

        #expect(model.currentStep == .calendarSelection)
        #expect(model.calendarGroups.isEmpty)
        #expect(model.microsoft365EmptyCalendarsMessage == OnboardingViewModel.microsoft365NoCalendarsMessage)
    }

    @Test("a failed read explains the empty calendar step")
    func readFailure() async throws {
        let tenant = StubGraphTenant()
        let harness = try await Microsoft365CalendarHarness(tenant: tenant, testName: "OnboardingUITests")
        defer { harness.fix.cleanup() }
        let model = OnboardingViewModel(core: harness.fix.core)
        await model.advance() // welcome -> permissions

        await tenant.setOffline(true)
        await harness.sync.refresh()

        #expect(model.microsoft365Error == "Couldn't reach Microsoft 365. Showing meetings from the last sync.")
        #expect(model.microsoft365EmptyCalendarsMessage == model.microsoft365Error)
    }
}
