import AppCore
import BiscottiTestSupport
import DataStore
import Foundation
import Permissions
import Testing
@testable import SettingsUI

@Suite("SettingsViewModel -- notification settings")
@MainActor
struct SettingsNotificationSettingsTests {
    // MARK: - Defaults

    @Test("monitorForMeetings defaults to true")
    func monitorDefault() throws {
        let fix = try makeCoreFixture()
        defer { fix.cleanup() }
        let viewModel = SettingsViewModel(core: fix.core)
        #expect(viewModel.monitorForMeetings == true)
    }

    @Test("stopRecordingAutomatically defaults to true")
    func stopRecordingDefault() throws {
        let fix = try makeCoreFixture()
        defer { fix.cleanup() }
        let viewModel = SettingsViewModel(core: fix.core)
        #expect(viewModel.stopRecordingAutomatically == true)
    }

    @Test("calendarNotificationMode defaults to allMeetings")
    func calendarModeDefault() throws {
        let fix = try makeCoreFixture()
        defer { fix.cleanup() }
        let viewModel = SettingsViewModel(core: fix.core)
        #expect(viewModel.calendarNotificationMode == .allMeetings)
    }

    // MARK: - Load from store

    @Test("load populates notification settings from store")
    func loadPopulatesSettings() async throws {
        let fix = try makeCoreFixture()
        defer { fix.cleanup() }

        try await fix.store.updateSettings { settings in
            settings.monitorForMeetings = false
            settings.stopRecordingAutomatically = false
            settings.calendarNotificationMode = .never
        }

        let viewModel = SettingsViewModel(core: fix.core)
        await viewModel.load()

        #expect(viewModel.monitorForMeetings == false)
        #expect(viewModel.stopRecordingAutomatically == false)
        #expect(viewModel.calendarNotificationMode == .never)
    }

    // MARK: - Setters persist and post

    @Test("setMonitorForMeetings persists and posts notification")
    func setMonitorPersists() async throws {
        let fix = try makeCoreFixture()
        defer { fix.cleanup() }
        let viewModel = SettingsViewModel(core: fix.core)

        var received = false
        let token = NotificationCenter.default.addObserver(
            forName: .monitorForMeetingsDidChange,
            object: nil,
            queue: .main
        ) { _ in received = true }
        defer { NotificationCenter.default.removeObserver(token) }

        await viewModel.setMonitorForMeetings(false)
        #expect(viewModel.monitorForMeetings == false)
        #expect(received)

        let settings = try await fix.store.settings()
        #expect(settings.monitorForMeetings == false)
    }

    @Test("setCalendarNotificationMode persists and posts notification")
    func setCalendarModePersists() async throws {
        let fix = try makeCoreFixture()
        defer { fix.cleanup() }
        let viewModel = SettingsViewModel(core: fix.core)

        var received = false
        let token = NotificationCenter.default.addObserver(
            forName: .calendarNotificationModeDidChange,
            object: nil,
            queue: .main
        ) { _ in received = true }
        defer { NotificationCenter.default.removeObserver(token) }

        await viewModel.setCalendarNotificationMode(.videoConferencing)
        #expect(viewModel.calendarNotificationMode == .videoConferencing)
        #expect(received)

        let settings = try await fix.store.settings()
        #expect(settings.calendarNotificationMode == .videoConferencing)
    }

    @Test("setStopRecordingAutomatically persists and posts notification")
    func setStopRecordingPersists() async throws {
        let fix = try makeCoreFixture()
        defer { fix.cleanup() }
        let viewModel = SettingsViewModel(core: fix.core)

        var received = false
        let token = NotificationCenter.default.addObserver(
            forName: .stopRecordingAutomaticallyDidChange,
            object: nil,
            queue: .main
        ) { _ in received = true }
        defer { NotificationCenter.default.removeObserver(token) }

        await viewModel.setStopRecordingAutomatically(false)
        #expect(viewModel.stopRecordingAutomatically == false)
        #expect(received)

        let settings = try await fix.store.settings()
        #expect(settings.stopRecordingAutomatically == false)
    }

    // MARK: - calendarNotificationsDisabled

    @Test("calendarNotificationsDisabled reflects calendar permission state")
    func calendarNotificationsDisabledReflectsPermission() throws {
        let fix = try makeCoreFixture()
        defer { fix.cleanup() }
        let viewModel = SettingsViewModel(core: fix.core)

        // Default calendarState is .notDetermined -> disabled
        #expect(viewModel.calendarNotificationsDisabled == true)

        // Authorize calendar
        fix.permissions.noteCalendar(.authorized)
        #expect(viewModel.calendarNotificationsDisabled == false)

        // Deny calendar
        fix.permissions.noteCalendar(.denied)
        #expect(viewModel.calendarNotificationsDisabled == true)
    }
}
