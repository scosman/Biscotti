import Foundation
import Notifications
import Testing
import UserNotifications

/// The "Recording started automatically" notification.
@Suite("Auto-recording notification")
@MainActor
struct AutoRecordingNotificationTests {
    @Test("content carries the app name, category and meeting ID")
    func content() async {
        let fake = FakeNotificationCenter()
        let service = NotificationService(provider: fake)
        _ = await service.requestAuthorization()

        let id = UUID()
        await service.present(.autoRecordingStarted(meetingID: id, appName: "Microsoft Teams"))

        #expect(fake.addedRequests.count == 1)
        let request = fake.addedRequests[0]
        #expect(request.identifier == "biscotti.notif.auto-recording.\(id.uuidString)")
        #expect(request.content.title == "Recording started automatically")
        #expect(request.content.subtitle == "App: Microsoft Teams")
        #expect(request.content.categoryIdentifier == "biscotti.auto-recording")
        #expect(request.content.userInfo["biscotti.meetingID"] as? String == id.uuidString)
    }

    @Test("category offers Stop Recording and a destructive Stop & Discard")
    func category() throws {
        let fake = FakeNotificationCenter()
        _ = NotificationService(provider: fake)
        let category = try #require(
            fake.setCategoriesCalls.first?.first { $0.identifier == "biscotti.auto-recording" }
        )
        #expect(category.actions.map(\.identifier) == [
            "biscotti.action.stop-recording",
            "biscotti.action.discard-recording"
        ])
        #expect(category.actions.map(\.title) == ["Stop Recording", "Stop & Discard"])
        #expect(category.actions[1].options.contains(.destructive))
    }

    @Test("Stop and Discard map to typed actions; tapping the banner does nothing")
    func mapping() async {
        let fake = FakeNotificationCenter()
        let service = NotificationService(provider: fake)
        let stream = service.actions()
        let id = UUID()
        let info: [AnyHashable: Any] = ["biscotti.kind": "auto-recording", "biscotti.meetingID": id.uuidString]

        #expect(!service.handleResponseValues(
            categoryID: "biscotti.auto-recording",
            actionID: UNNotificationDefaultActionIdentifier,
            userInfo: info
        ))
        #expect(service.handleResponseValues(
            categoryID: "biscotti.auto-recording", actionID: "biscotti.action.stop-recording", userInfo: info
        ))
        #expect(service.handleResponseValues(
            categoryID: "biscotti.auto-recording", actionID: "biscotti.action.discard-recording", userInfo: info
        ))

        var iterator = stream.makeAsyncIterator()
        #expect(await iterator.next() == .stopRecording(meetingID: id))
        #expect(await iterator.next() == .discardRecording(meetingID: id))
    }

    @Test("a missing meeting ID is ignored")
    func missingID() {
        let service = NotificationService(provider: FakeNotificationCenter())
        #expect(!service.handleResponseValues(
            categoryID: "biscotti.auto-recording",
            actionID: "biscotti.action.stop-recording",
            userInfo: [:]
        ))
    }

    @Test("cancel removes pending and delivered")
    func cancel() async {
        let fake = FakeNotificationCenter()
        let service = NotificationService(provider: fake)
        let id = UUID()
        await service.cancelAutoRecordingStarted(meetingID: id)
        let expected = ["biscotti.notif.auto-recording.\(id.uuidString)"]
        #expect(fake.removedPendingIDs.last == expected)
        #expect(fake.removedDeliveredIDs.last == expected)
    }
}
