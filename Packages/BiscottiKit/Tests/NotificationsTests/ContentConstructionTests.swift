import Foundation
import Notifications
import Testing

@Suite("Content construction")
struct ContentConstructionTests {
    @Test("Meeting-starting content uses event title and timeSensitive")
    @MainActor
    func meetingStartingContentUsesEventTitle() async {
        let fake = FakeNotificationCenter()
        let service = NotificationService(provider: fake)
        _ = await service.requestAuthorization()

        await service.present(
            .meetingStarting(eventKey: "k", title: "Standup", joinURL: nil)
        )

        #expect(fake.addedRequests.count == 1)
        let content = fake.addedRequests[0].content
        #expect(content.title == "Standup")
        #expect(content.categoryIdentifier == "biscotti.meeting-starting")
        #expect(content.interruptionLevel == .timeSensitive)
        #expect(content.sound == nil)
        #expect(content.userInfo["biscotti.eventKey"] as? String == "k")
        #expect(content.userInfo["biscotti.kind"] as? String == "meeting-starting")
    }

    @Test("Meeting-starting with joinURL uses join category and timeSensitive")
    @MainActor
    func meetingStartingWithJoinUsesJoinCategory() async throws {
        let fake = FakeNotificationCenter()
        let service = NotificationService(provider: fake)
        _ = await service.requestAuthorization()

        let url = try #require(URL(string: "https://zoom.us/j/123"))
        await service.present(
            .meetingStarting(eventKey: "k2", title: "1:1", joinURL: url)
        )

        #expect(fake.addedRequests.count == 1)
        let content = fake.addedRequests[0].content
        #expect(
            content.categoryIdentifier == "biscotti.meeting-starting-with-join"
        )
        #expect(content.interruptionLevel == .timeSensitive)
        #expect(
            content.userInfo["biscotti.joinURL"] as? String
                == "https://zoom.us/j/123"
        )
    }

    @Test("Ad-hoc content uses new copy format and timeSensitive")
    @MainActor
    func adHocContentUsesNewCopy() async {
        let fake = FakeNotificationCenter()
        let service = NotificationService(provider: fake)
        _ = await service.requestAuthorization()

        await service.present(
            .adHocDetected(bundleID: "us.zoom.xos", appName: "Zoom")
        )

        #expect(fake.addedRequests.count == 1)
        let content = fake.addedRequests[0].content
        #expect(content.title == "Meeting detected")
        #expect(content.subtitle == "App: Zoom")
        #expect(content.body == "")
        #expect(content.interruptionLevel == .timeSensitive)
        #expect(content.categoryIdentifier == "biscotti.ad-hoc-detected")
        #expect(content.userInfo["biscotti.bundleID"] as? String == "us.zoom.xos")
    }

    @Test("Stop-countdown content shows seconds")
    @MainActor
    func stopCountdownContentShowsSeconds() async {
        let fake = FakeNotificationCenter()
        let service = NotificationService(provider: fake)
        _ = await service.requestAuthorization()

        let id = UUID()
        await service.present(
            .stopCountdown(meetingID: id, secondsRemaining: 10)
        )

        #expect(fake.addedRequests.count == 1)
        let content = fake.addedRequests[0].content
        #expect(content.title.contains("10"))
        #expect(content.categoryIdentifier == "biscotti.stop-countdown")
        #expect(content.sound == nil)
    }
}
