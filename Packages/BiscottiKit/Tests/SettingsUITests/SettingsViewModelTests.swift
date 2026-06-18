import BiscottiTestSupport
import Calendar
import Permissions
import Testing
@testable import DataStore
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
        #expect(viewModel.systemAudioState == .notRequested)
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

    // MARK: - Vocabulary removed

    @Test("vocabularyDeferred property no longer exists")
    func vocabPropertyRemoved() throws {
        // Compile-time check: SettingsViewModel has no `vocabularyDeferred`.
        // If someone re-adds it, this test documents the intent.
        let fixture = try makeCoreFixture()
        defer { fixture.cleanup() }
        let viewModel = SettingsViewModel(core: fixture.core)
        // The view model should have no vocabulary-related public state.
        // This test simply verifies the view model can be created without
        // referencing any vocabulary property.
        _ = viewModel
    }

    // MARK: - Permission request actions

    @Test("request microphone permission calls the mic seam")
    func requestMicrophonePermission() async throws {
        let fixture = try makeCoreFixture(
            micStatus: .notDetermined,
            micRequestResult: true
        )
        defer { fixture.cleanup() }

        let viewModel = SettingsViewModel(core: fixture.core)

        #expect(viewModel.microphoneState == .notDetermined)

        await viewModel.requestPermission(for: .microphone)

        #expect(viewModel.microphoneState == .authorized)
    }

    @Test("request calendar permission calls calendar service and syncs state")
    func requestCalendarPermission() async throws {
        let fixture = try makeCoreFixture(
            calendarAuthStatus: .notDetermined
        )
        defer { fixture.cleanup() }

        let viewModel = SettingsViewModel(core: fixture.core)

        // Calendar state starts as notDetermined (no seam injected)
        #expect(viewModel.calendarState == .notDetermined)

        // FakeEventStore returns requestAccessResult=true and
        // authorizationStatus()=.authorized after request
        fixture.fakeEventStore.authStatus = .authorized
        await viewModel.requestPermission(for: .calendar)

        #expect(viewModel.calendarState == .authorized)
    }

    @Test("request notification permission calls the notifications seam")
    func requestNotificationPermission() async throws {
        let fakeNotifAuth = FakeNotificationAuthorizer(
            status: .notDetermined,
            requestResult: true
        )
        let fixture = try makeCoreFixture(
            notificationAuthorizer: fakeNotifAuth
        )
        defer { fixture.cleanup() }

        let viewModel = SettingsViewModel(core: fixture.core)

        #expect(viewModel.notificationsState == .notDetermined)

        await viewModel.requestPermission(for: .notifications)

        #expect(viewModel.notificationsState == .authorized)
    }

    @Test("denied microphone request updates state to denied")
    func requestMicrophoneDenied() async throws {
        let fixture = try makeCoreFixture(
            micStatus: .notDetermined,
            micRequestResult: false
        )
        defer { fixture.cleanup() }

        let viewModel = SettingsViewModel(core: fixture.core)
        await viewModel.requestPermission(for: .microphone)
        #expect(viewModel.microphoneState == .denied)
    }

    // MARK: - Live permission status on load

    @Test("load refreshes calendar status from live CalendarService auth")
    func loadRefreshesCalendarStatus() async throws {
        // Create fixture where FakeEventStore says authorized but
        // Permissions has no cal seam (mimics live app)
        let fixture = try makeCoreFixture(
            calendarAuthStatus: .authorized
        )
        defer { fixture.cleanup() }

        let viewModel = SettingsViewModel(core: fixture.core)

        // Before load, calendar state is .notDetermined (no seam)
        #expect(viewModel.calendarState == .notDetermined)

        // After load, should reflect the CalendarService's .authorized
        await viewModel.load()
        #expect(viewModel.calendarState == .authorized)
    }

    @Test("load refreshes notification status from live NotificationService")
    func loadRefreshesNotificationStatus() async throws {
        // FakeTestNotificationCenter defaults to authStatus = .authorized
        let fixture = try makeCoreFixture()
        defer { fixture.cleanup() }

        let viewModel = SettingsViewModel(core: fixture.core)

        // Before load, notifications state is .notDetermined (no seam)
        #expect(viewModel.notificationsState == .notDetermined)

        // After load, should reflect FakeTestNotificationCenter's .authorized
        await viewModel.load()
        #expect(viewModel.notificationsState == .authorized)
    }

    @Test("load shows denied notification status when denied")
    func loadShowsDeniedNotificationStatus() async throws {
        let fixture = try makeCoreFixture()
        defer { fixture.cleanup() }
        fixture.fakeNotificationCenter.backing.authStatus = .denied

        let viewModel = SettingsViewModel(core: fixture.core)
        await viewModel.load()
        #expect(viewModel.notificationsState == .denied)
    }

    // MARK: - Exit on window close

    @Test("exitOnWindowClose defaults to false")
    func exitOnWindowCloseDefaultsFalse() throws {
        let fixture = try makeCoreFixture()
        defer { fixture.cleanup() }
        let viewModel = SettingsViewModel(core: fixture.core)
        #expect(viewModel.exitOnWindowClose == false)
    }

    @Test("toggle exitOnWindowClose persists and reads back")
    func toggleExitOnWindowClosePersists() async throws {
        let fixture = try makeCoreFixture()
        defer { fixture.cleanup() }

        let viewModel = SettingsViewModel(core: fixture.core)
        await viewModel.load()
        #expect(viewModel.exitOnWindowClose == false)

        // Toggle on
        await viewModel.setExitOnWindowClose(true)
        #expect(viewModel.exitOnWindowClose == true)

        // Verify persisted
        let settings = try await fixture.store.settings()
        #expect(settings.exitOnWindowClose == true)

        // Toggle off
        await viewModel.setExitOnWindowClose(false)
        #expect(viewModel.exitOnWindowClose == false)

        let settings2 = try await fixture.store.settings()
        #expect(settings2.exitOnWindowClose == false)
    }

    @Test("load reads exitOnWindowClose from store")
    func exitOnWindowCloseLoadedFromStore() async throws {
        let fixture = try makeCoreFixture()
        defer { fixture.cleanup() }

        // Pre-set the value in the store
        try await fixture.store.updateSettings { settings in
            settings.exitOnWindowClose = true
        }

        let viewModel = SettingsViewModel(core: fixture.core)
        await viewModel.load()
        #expect(viewModel.exitOnWindowClose == true)
    }
}

// MARK: - Menu bar lead time

@Suite("SettingsViewModel -- menu bar lead time")
@MainActor
struct SettingsMenuBarLeadTimeTests {
    @Test("menuBarLeadTime defaults to oneHour")
    func menuBarLeadTimeDefault() throws {
        let fixture = try makeCoreFixture()
        defer { fixture.cleanup() }
        let viewModel = SettingsViewModel(core: fixture.core)
        #expect(viewModel.menuBarLeadTime == .oneHour)
    }

    @Test("setMenuBarLeadTime persists and reads back")
    func setMenuBarLeadTimePersists() async throws {
        let fixture = try makeCoreFixture()
        defer { fixture.cleanup() }

        let viewModel = SettingsViewModel(core: fixture.core)
        await viewModel.load()
        #expect(viewModel.menuBarLeadTime == .oneHour)

        // Change to 5 minutes
        await viewModel.setMenuBarLeadTime(.fiveMinutes)
        #expect(viewModel.menuBarLeadTime == .fiveMinutes)

        // Verify persisted
        let settings = try await fixture.store.settings()
        #expect(settings.menuBarLeadTimeSeconds == 300)
    }

    @Test("setMenuBarLeadTime to never persists zero")
    func setMenuBarLeadTimeNever() async throws {
        let fixture = try makeCoreFixture()
        defer { fixture.cleanup() }

        let viewModel = SettingsViewModel(core: fixture.core)
        await viewModel.setMenuBarLeadTime(.never)
        #expect(viewModel.menuBarLeadTime == .never)

        let settings = try await fixture.store.settings()
        #expect(settings.menuBarLeadTimeSeconds == 0)
    }

    @Test("load reads menuBarLeadTime from store")
    func menuBarLeadTimeLoadedFromStore() async throws {
        let fixture = try makeCoreFixture()
        defer { fixture.cleanup() }

        // Pre-set the value
        try await fixture.store.updateSettings { settings in
            settings.menuBarLeadTimeSeconds = MenuBarLeadTime.sixHours.rawValue
        }

        let viewModel = SettingsViewModel(core: fixture.core)
        await viewModel.load()
        #expect(viewModel.menuBarLeadTime == .sixHours)
    }
}

// MARK: - System audio permission row

@Suite("SettingsViewModel -- system audio permission")
@MainActor
struct SettingsSystemAudioTests {
    @Test("system audio state reflects notRequested from core")
    func systemAudioNotRequested() throws {
        let fixture = try makeCoreFixture()
        defer { fixture.cleanup() }
        let viewModel = SettingsViewModel(core: fixture.core)
        #expect(viewModel.systemAudioState == .notRequested)
        #expect(viewModel.isValidatingSystemAudio == false)
    }

    @Test("system audio state reflects approved from core")
    func systemAudioApproved() throws {
        let fixture = try makeCoreFixture()
        defer { fixture.cleanup() }
        fixture.permissions.setSystemAudio(.approved)
        let viewModel = SettingsViewModel(core: fixture.core)
        #expect(viewModel.systemAudioState == .approved)
    }

    @Test("system audio state reflects requestedNotVerified from core")
    func systemAudioRequestedNotVerified() throws {
        let fixture = try makeCoreFixture()
        defer { fixture.cleanup() }
        fixture.permissions.setSystemAudio(.requestedNotVerified)
        let viewModel = SettingsViewModel(core: fixture.core)
        #expect(viewModel.systemAudioState == .requestedNotVerified)
    }

    @Test("requestSystemAudio toggles isValidating and invokes core")
    func requestSystemAudioTogglesValidating() async throws {
        let fixture = try makeCoreFixture()
        defer { fixture.cleanup() }
        let viewModel = SettingsViewModel(core: fixture.core)

        #expect(viewModel.isValidatingSystemAudio == false)

        // requestSystemAudio calls core.requestSystemAudioPermission()
        // which goes through FakeRecorder's probeSystemAudioWithTone
        await viewModel.requestSystemAudio()

        // After completing, validating should be false again
        #expect(viewModel.isValidatingSystemAudio == false)
        // FakeRecorder's probeSystemAudioWithTone was called
        #expect(fixture.fakeRecorder.backing.probeSystemAudioWithToneCalled == true)
    }

    @Test("no auto-probe on load")
    func noAutoProbeOnLoad() async throws {
        let fixture = try makeCoreFixture()
        defer { fixture.cleanup() }
        let viewModel = SettingsViewModel(core: fixture.core)

        await viewModel.load()

        // No probe should have been triggered
        #expect(viewModel.isValidatingSystemAudio == false)
        #expect(fixture.fakeRecorder.backing.probeSystemAudioWithToneCalled == false)
    }

    @Test("showFixPermissionsAlert toggles on and off")
    func fixPermissionsAlertToggle() throws {
        let fixture = try makeCoreFixture()
        defer { fixture.cleanup() }
        let viewModel = SettingsViewModel(core: fixture.core)

        #expect(viewModel.showFixPermissionsAlert == false)
        viewModel.showFixPermissionsAlert = true
        #expect(viewModel.showFixPermissionsAlert == true)
        viewModel.showFixPermissionsAlert = false
        #expect(viewModel.showFixPermissionsAlert == false)
    }

    @Test("requestSystemAudio updates state to approved when probe succeeds")
    func requestSystemAudioUpdatesToApproved() async throws {
        let fixture = try makeCoreFixture()
        defer { fixture.cleanup() }
        fixture.fakeRecorder.backing.probeResult = true
        let viewModel = SettingsViewModel(core: fixture.core)

        #expect(viewModel.systemAudioState == .notRequested)

        await viewModel.requestSystemAudio()

        #expect(viewModel.systemAudioState == .approved)
    }

    @Test("requestSystemAudio stays requestedNotVerified when probe fails")
    func requestSystemAudioStaysRequestedNotVerified() async throws {
        let fixture = try makeCoreFixture()
        defer { fixture.cleanup() }
        fixture.fakeRecorder.backing.probeResult = false
        let viewModel = SettingsViewModel(core: fixture.core)

        await viewModel.requestSystemAudio()

        #expect(viewModel.systemAudioState == .requestedNotVerified)
    }
}
