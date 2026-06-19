import Foundation
import Notifications
import Testing

@Suite("Request identifier dedup / replace")
struct RequestIdentifierTests {
    @Test("Meeting-start request ID contains event key")
    @MainActor
    func meetingStartRequestIDContainsEventKey() async {
        let fake = FakeNotificationCenter()
        let service = NotificationService(provider: fake)
        _ = await service.requestAuthorization()

        await service.present(
            .meetingStarting(eventKey: "abc", title: "A", joinURL: nil)
        )
        await service.present(
            .meetingStarting(eventKey: "xyz", title: "B", joinURL: nil)
        )

        #expect(fake.addedRequests.count == 2)
        let id0 = fake.addedRequests[0].identifier
        let id1 = fake.addedRequests[1].identifier
        #expect(id0 != id1)
        #expect(id0.contains("abc"))
        #expect(id1.contains("xyz"))
    }

    @Test("Countdown present reuses same identifier for same meeting")
    @MainActor
    func countdownPresentReusesIdentifier() async {
        let fake = FakeNotificationCenter()
        let service = NotificationService(provider: fake)
        _ = await service.requestAuthorization()

        let meetingID = UUID()
        await service.present(
            .stopCountdown(meetingID: meetingID, secondsRemaining: 15)
        )
        await service.present(
            .stopCountdown(meetingID: meetingID, secondsRemaining: 10)
        )

        #expect(fake.addedRequests.count == 2)
        #expect(
            fake.addedRequests[0].identifier
                == fake.addedRequests[1].identifier
        )
        // Second present carries the updated seconds in its title
        #expect(fake.addedRequests[1].content.title.contains("10"))
    }

    @Test("Ad-hoc request ID contains bundle ID")
    @MainActor
    func adHocRequestIDContainsBundleID() async {
        let fake = FakeNotificationCenter()
        let service = NotificationService(provider: fake)
        _ = await service.requestAuthorization()

        await service.present(
            .adHocDetected(bundleID: "us.zoom.xos", appName: "Zoom")
        )
        await service.present(
            .adHocDetected(bundleID: "com.microsoft.teams", appName: "Teams")
        )
        await service.present(
            .adHocDetected(bundleID: "us.zoom.xos", appName: "Zoom")
        )

        #expect(fake.addedRequests.count == 3)
        let zoomID = fake.addedRequests[0].identifier
        let teamsID = fake.addedRequests[1].identifier
        let zoomID2 = fake.addedRequests[2].identifier

        #expect(zoomID != teamsID)
        #expect(zoomID == zoomID2)
    }
}
