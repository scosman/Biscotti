import Foundation
import Notifications
import Testing

@Suite("cancelAdHocDetected")
struct CancelAdHocTests {
    @Test("Cancels presented ad-hoc notification identifiers")
    @MainActor
    func cancelsAdHocIDs() async {
        let fake = FakeNotificationCenter()
        let service = NotificationService(provider: fake)
        _ = await service.requestAuthorization()

        // Present an ad-hoc detection notification.
        await service.present(
            .adHocDetected(bundleID: "us.zoom.xos", appName: "Zoom")
        )

        #expect(fake.addedRequests.count == 1)
        let adHocID = fake.addedRequests[0].identifier

        // Cancel should remove the ad-hoc notification.
        await service.cancelAdHocDetected()

        #expect(fake.removedPendingIDs.count == 1)
        #expect(fake.removedPendingIDs[0] == [adHocID])
        #expect(fake.removedDeliveredIDs.count == 1)
        #expect(fake.removedDeliveredIDs[0] == [adHocID])
    }

    @Test("Second cancel is a no-op after tracking is cleared")
    @MainActor
    func secondCancelIsNoOp() async {
        let fake = FakeNotificationCenter()
        let service = NotificationService(provider: fake)
        _ = await service.requestAuthorization()

        await service.present(
            .adHocDetected(bundleID: "us.zoom.xos", appName: "Zoom")
        )

        await service.cancelAdHocDetected()
        let pendingCountAfterFirst = fake.removedPendingIDs.count

        // Second cancel should not add removal calls.
        await service.cancelAdHocDetected()
        #expect(fake.removedPendingIDs.count == pendingCountAfterFirst)
    }

    @Test("Cancels multiple ad-hoc notifications")
    @MainActor
    func cancelsMultipleAdHocIDs() async {
        let fake = FakeNotificationCenter()
        let service = NotificationService(provider: fake)
        _ = await service.requestAuthorization()

        await service.present(
            .adHocDetected(bundleID: "us.zoom.xos", appName: "Zoom")
        )
        await service.present(
            .adHocDetected(bundleID: "com.google.Chrome", appName: "Chrome")
        )

        #expect(fake.addedRequests.count == 2)

        await service.cancelAdHocDetected()

        // Both IDs should be in the single removal call.
        #expect(fake.removedPendingIDs.count == 1)
        let removedIDs = Set(fake.removedPendingIDs[0])
        #expect(removedIDs.count == 2)
        #expect(removedIDs.contains(fake.addedRequests[0].identifier))
        #expect(removedIDs.contains(fake.addedRequests[1].identifier))
    }

    @Test("No-op when no ad-hoc notifications were presented")
    @MainActor
    func noOpWhenEmpty() async {
        let fake = FakeNotificationCenter()
        let service = NotificationService(provider: fake)

        await service.cancelAdHocDetected()

        #expect(fake.removedPendingIDs.isEmpty)
        #expect(fake.removedDeliveredIDs.isEmpty)
    }

    @Test("Non-ad-hoc notifications are not tracked for cancellation")
    @MainActor
    func nonAdHocNotTracked() async {
        let fake = FakeNotificationCenter()
        let service = NotificationService(provider: fake)
        _ = await service.requestAuthorization()

        // Present a meeting-starting notification (not ad-hoc).
        await service.present(
            .meetingStarting(eventKey: "ev-1", title: "Standup", joinURL: nil)
        )

        await service.cancelAdHocDetected()

        // No removal should happen since only ad-hoc IDs are tracked.
        #expect(fake.removedPendingIDs.isEmpty)
    }
}
