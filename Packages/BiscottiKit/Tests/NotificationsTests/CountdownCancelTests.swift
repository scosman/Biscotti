import Foundation
import Notifications
import Testing

@Suite("Countdown cancel")
struct CountdownCancelTests {
    @Test("Cancel countdown removes pending and delivered")
    @MainActor
    func cancelCountdownRemovesPendingAndDelivered() async {
        let fake = FakeNotificationCenter()
        let service = NotificationService(provider: fake)

        let meetingID = UUID()
        await service.cancelCountdown(meetingID: meetingID)

        #expect(fake.removedPendingIDs.count == 1)
        #expect(fake.removedDeliveredIDs.count == 1)

        let expectedID = "biscotti.notif.countdown.\(meetingID.uuidString)"
        #expect(fake.removedPendingIDs[0] == [expectedID])
        #expect(fake.removedDeliveredIDs[0] == [expectedID])
    }
}
