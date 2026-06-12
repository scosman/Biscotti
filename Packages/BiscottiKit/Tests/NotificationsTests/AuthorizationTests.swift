import Foundation
import Notifications
import Testing

@Suite("Authorization")
struct AuthorizationTests {
    @Test("requestAuthorization returns provider result: granted")
    @MainActor
    func requestAuthorizationReturnsGranted() async {
        let fake = FakeNotificationCenter()
        fake.authorizationGranted = true
        let service = NotificationService(provider: fake)

        let result = await service.requestAuthorization()
        #expect(result == true)
    }

    @Test("requestAuthorization returns provider result: denied")
    @MainActor
    func requestAuthorizationReturnsDenied() async {
        let fake = FakeNotificationCenter()
        fake.authorizationGranted = false
        let service = NotificationService(provider: fake)

        let result = await service.requestAuthorization()
        #expect(result == false)
    }

    @Test("Denied auth makes present no-op")
    @MainActor
    func deniedAuthMakesPresentNoOp() async {
        let fake = FakeNotificationCenter()
        fake.currentStatus = .denied
        let service = NotificationService(provider: fake)

        await service.present(
            .adHocDetected(bundleID: "us.zoom.xos", appName: "Zoom")
        )

        #expect(fake.addedRequests.isEmpty)
    }

    @Test("Cancel countdown works when denied")
    @MainActor
    func cancelCountdownWorksWhenDenied() async {
        let fake = FakeNotificationCenter()
        fake.currentStatus = .denied
        let service = NotificationService(provider: fake)

        let meetingID = UUID()
        await service.cancelCountdown(meetingID: meetingID)

        #expect(fake.removedPendingIDs.count == 1)
        #expect(fake.removedDeliveredIDs.count == 1)
    }
}
