import BiscottiTestSupport
import Permissions
import Testing
@testable import SettingsUI

@Suite("SettingsViewModel -- Notification authorization wiring")
@MainActor
struct SettingsNotificationTests {
    @Test("Request notifications button invokes provider and updates state")
    func requestNotificationsInvokesProvider() async throws {
        let fakeNotif = FakeNotificationAuthorizer(
            status: .notDetermined, requestResult: true
        )
        let fixture = try makeCoreFixture(
            notificationAuthorizer: fakeNotif
        )
        defer { fixture.cleanup() }

        let viewModel = SettingsViewModel(core: fixture.core)

        #expect(viewModel.notificationsState == .notDetermined)

        await viewModel.requestPermission(for: .notifications)

        #expect(fakeNotif.backing.requestCalled == true)
        #expect(viewModel.notificationsState == .authorized)
    }

    @Test("Request notifications denied updates state to denied")
    func requestNotificationsDeniedUpdatesState() async throws {
        let fakeNotif = FakeNotificationAuthorizer(
            status: .notDetermined, requestResult: false
        )
        let fixture = try makeCoreFixture(
            notificationAuthorizer: fakeNotif
        )
        defer { fixture.cleanup() }

        let viewModel = SettingsViewModel(core: fixture.core)
        await viewModel.requestPermission(for: .notifications)

        #expect(fakeNotif.backing.requestCalled == true)
        #expect(viewModel.notificationsState == .denied)
    }

    @Test("NotificationService request calls through injected provider")
    func notificationServiceCallsThroughProvider() async throws {
        let fixture = try makeCoreFixture()
        defer { fixture.cleanup() }

        // The FakeTestNotificationCenter in the fixture defaults to
        // authGranted=true. Verify the service calls through it.
        let granted = await fixture.notificationService
            .requestAuthorization()
        #expect(granted == true)

        // Flip to denied and verify
        fixture.fakeNotificationCenter.backing.authGranted = false
        let denied = await fixture.notificationService
            .requestAuthorization()
        #expect(denied == false)
    }
}
