import BiscottiTestSupport
import Calendar
import DataStore
import Testing
@testable import SettingsUI

@Suite("SettingsViewModel")
@MainActor
struct SettingsViewModelTests {
    // MARK: - Calendar grouping

    @Test("calendars group by source title")
    func calendarGroupsBySource() {
        let infos = [
            CalendarInfo(id: "c1", title: "Work", colorHex: "#0066CC", sourceTitle: "iCloud"),
            CalendarInfo(id: "c2", title: "Family", colorHex: "#33CC33", sourceTitle: "iCloud"),
            CalendarInfo(id: "c3", title: "Team", colorHex: "#CC0000", sourceTitle: "Google")
        ]

        let groups = SettingsViewModel.groupCalendars(infos)

        #expect(groups.count == 2)
        #expect(groups[0].sourceTitle == "Google")
        #expect(groups[0].calendars.count == 1)
        #expect(groups[1].sourceTitle == "iCloud")
        #expect(groups[1].calendars.count == 2)
    }

    @Test("all calendars enabled when enabledCalendarIDs is nil")
    func calendarAllEnabledWhenNil() throws {
        let fixture = try makeCoreFixture()
        let viewModel = SettingsViewModel(core: fixture.core)
        // Default: enabledCalendarIDs is nil (all enabled)
        #expect(viewModel.isCalendarEnabled("any-id") == true)
        #expect(viewModel.isCalendarEnabled("another-id") == true)
        fixture.cleanup()
    }

    @Test("toggle calendar persists enabled IDs")
    func calendarTogglePersistsEnabledIDs() async throws {
        let fixture = try makeCoreFixture(
            calendarInfos: [
                CalendarInfo(id: "c1", title: "Work", colorHex: "#0066CC", sourceTitle: "iCloud"),
                CalendarInfo(id: "c2", title: "Family", colorHex: "#33CC33", sourceTitle: "iCloud")
            ]
        )
        let viewModel = SettingsViewModel(core: fixture.core)
        await viewModel.load()

        // All enabled initially
        #expect(viewModel.isCalendarEnabled("c1") == true)
        #expect(viewModel.isCalendarEnabled("c2") == true)

        // Toggle c1 off
        await viewModel.toggleCalendar("c1")

        #expect(viewModel.isCalendarEnabled("c1") == false)
        #expect(viewModel.isCalendarEnabled("c2") == true)

        // Verify persisted
        let settings = try await fixture.store.settings()
        #expect(settings.enabledCalendarIDs != nil)
        #expect(settings.enabledCalendarIDs?.contains("c1") == false)
        #expect(settings.enabledCalendarIDs?.contains("c2") == true)

        fixture.cleanup()
    }

    @Test("permissions show current state")
    func permissionsShowCurrentState() throws {
        let fixture = try makeCoreFixture()
        let viewModel = SettingsViewModel(core: fixture.core)
        #expect(viewModel.microphoneState == .authorized)
        #expect(viewModel.systemAudioState == .notDetermined)
        #expect(viewModel.calendarState == .notDetermined)
        #expect(viewModel.notificationsState == .notDetermined)
        fixture.cleanup()
    }

    @Test("empty calendar groups when no calendars")
    func emptyCalendarGroups() {
        let groups = SettingsViewModel.groupCalendars([])
        #expect(groups.isEmpty)
    }

    @Test("calendars sorted within group")
    func calendarsSortedWithinGroup() {
        let infos = [
            CalendarInfo(id: "c2", title: "Zebra", colorHex: "#000", sourceTitle: "iCloud"),
            CalendarInfo(id: "c1", title: "Alpha", colorHex: "#000", sourceTitle: "iCloud")
        ]
        let groups = SettingsViewModel.groupCalendars(infos)
        #expect(groups[0].calendars[0].title == "Alpha")
        #expect(groups[0].calendars[1].title == "Zebra")
    }

    // MARK: - Launch at login

    @Test("toggle launch at login persists to settings")
    func settingsToggleLaunchAtLogin() async throws {
        let fixture = try makeCoreFixture()
        defer { fixture.cleanup() }

        let viewModel = SettingsViewModel(
            core: fixture.core,
            readLaunchAtLoginStatus: { false }
        )
        await viewModel.load()

        // Seam says not registered -> toggle shows false
        #expect(viewModel.launchAtLogin == false)

        // Toggle on
        await viewModel.setLaunchAtLogin(true)
        #expect(viewModel.launchAtLogin == true)

        // Verify persisted
        let settings = try await fixture.store.settings()
        #expect(settings.launchAtLogin == true)

        // Toggle off
        await viewModel.setLaunchAtLogin(false)
        #expect(viewModel.launchAtLogin == false)

        let settings2 = try await fixture.store.settings()
        #expect(settings2.launchAtLogin == false)
    }

    @Test("launch at login reflects system status on load")
    func launchAtLoginReflectsSystemStatus() async throws {
        let fixture = try makeCoreFixture()
        defer { fixture.cleanup() }

        // System says enabled -> toggle should show true
        let viewModel = SettingsViewModel(
            core: fixture.core,
            readLaunchAtLoginStatus: { true }
        )
        await viewModel.load()
        #expect(viewModel.launchAtLogin == true)

        // System says disabled -> toggle should show false
        let viewModel2 = SettingsViewModel(
            core: fixture.core,
            readLaunchAtLoginStatus: { false }
        )
        await viewModel2.load()
        #expect(viewModel2.launchAtLogin == false)
    }

    // MARK: - Vocabulary stub

    @Test("vocabulary section is stubbed/deferred")
    func settingsVocabSectionStubbed() throws {
        let fixture = try makeCoreFixture()
        defer { fixture.cleanup() }

        let viewModel = SettingsViewModel(core: fixture.core)
        #expect(viewModel.vocabularyDeferred == true)
    }
}
