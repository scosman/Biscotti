import BiscottiTestSupport
import Permissions
import Testing
@testable import OnboardingUI

@Suite("OnboardingViewModel -- Notification authorization wiring")
@MainActor
struct OnboardingNotificationTests {
    @Test("requestNotifications invokes provider requestAuthorization and updates granted state")
    func requestNotificationsInvokesProvider() async throws {
        let fakeNotif = FakeNotificationAuthorizer(
            status: .notDetermined, requestResult: true
        )
        let fixture = try makeCoreFixture(
            notificationAuthorizer: fakeNotif
        )
        defer { fixture.cleanup() }

        let model = OnboardingViewModel(core: fixture.core)

        // Walk to the permissions step
        await model.advance() // welcome -> permissions

        #expect(model.currentStep == .permissions)
        #expect(model.notificationsGranted == false)

        // Request notification permission
        await model.requestNotifications()

        // Verify the fake's request was called
        #expect(fakeNotif.backing.requestCalled == true)
        // Verify the granted state is updated
        #expect(model.notificationsGranted == true)
        // Verify Permissions state is updated
        #expect(fixture.permissions.notifications == .authorized)
    }

    @Test("requestNotifications denied updates state to denied")
    func requestNotificationsDeniedUpdatesState() async throws {
        let fakeNotif = FakeNotificationAuthorizer(
            status: .notDetermined, requestResult: false
        )
        let fixture = try makeCoreFixture(
            notificationAuthorizer: fakeNotif
        )
        defer { fixture.cleanup() }

        let model = OnboardingViewModel(core: fixture.core)

        // Walk to the permissions step
        await model.advance() // welcome -> permissions

        await model.requestNotifications()

        #expect(fakeNotif.backing.requestCalled == true)
        #expect(model.notificationsGranted == false)
        #expect(fixture.permissions.notifications == .denied)
    }

    @Test("Without notification authorizer, request returns false (the pre-fix bug)")
    func withoutAuthorizerRequestReturnsFalse() async throws {
        // No notificationAuthorizer injected -- mimics the old broken wiring
        let fixture = try makeCoreFixture()
        defer { fixture.cleanup() }

        let model = OnboardingViewModel(core: fixture.core)

        await model.advance() // welcome -> permissions

        await model.requestNotifications()

        // With no authorizer, requestNotifications returns false
        #expect(model.notificationsGranted == false)
    }

    @Test("setNotificationAuthorizer wires in authorizer after construction")
    func setNotificationAuthorizerWiresAfterConstruction() async throws {
        let fixture = try makeCoreFixture()
        defer { fixture.cleanup() }

        // Initially no authorizer -- request fails
        let result1 = await fixture.permissions.requestNotifications()
        #expect(result1 == false)

        // Wire in a fake authorizer after construction
        let fakeNotif = FakeNotificationAuthorizer(
            status: .notDetermined, requestResult: true
        )
        fixture.permissions.setNotificationAuthorizer(fakeNotif)

        // Now request should succeed
        let result2 = await fixture.permissions.requestNotifications()
        #expect(result2 == true)
        #expect(fakeNotif.backing.requestCalled == true)
        #expect(fixture.permissions.notifications == .authorized)
    }
}
