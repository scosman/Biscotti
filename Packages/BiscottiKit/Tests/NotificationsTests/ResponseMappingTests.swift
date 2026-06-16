import Foundation
import Notifications
import Testing
import UserNotifications

@Suite("Delegate response mapping")
struct ResponseMappingTests {
    @Test("Open & Record on meeting-starting maps to openAndRecord")
    @MainActor
    func delegateResponseMapsToOpenAndRecord() async {
        let fake = FakeNotificationCenter()
        let service = NotificationService(provider: fake)
        let stream = service.actions()

        let result = service.handleResponseValues(
            categoryID: "biscotti.meeting-starting",
            actionID: "biscotti.action.open-and-record",
            userInfo: [
                "biscotti.kind": "meeting-starting",
                "biscotti.eventKey": "ev-123"
            ]
        )

        #expect(result == true)

        var iterator = stream.makeAsyncIterator()
        let action = await iterator.next()
        #expect(action == .openAndRecord(eventKey: "ev-123"))
    }

    @Test("Join action maps to join URL")
    @MainActor
    func joinActionMapsToJoinURL() async throws {
        let fake = FakeNotificationCenter()
        let service = NotificationService(provider: fake)
        let stream = service.actions()

        let url = "https://zoom.us/j/999"
        let result = service.handleResponseValues(
            categoryID: "biscotti.meeting-starting-with-join",
            actionID: "biscotti.action.join",
            userInfo: [
                "biscotti.kind": "meeting-starting",
                "biscotti.joinURL": url
            ]
        )

        #expect(result == true)

        var iterator = stream.makeAsyncIterator()
        let action = await iterator.next()
        #expect(try action == .join(#require(URL(string: url))))
    }

    @Test("Ad-hoc record maps to openAndRecord with nil key")
    @MainActor
    func adHocRecordActionMapsToOpenAndRecordNilKey() async {
        let fake = FakeNotificationCenter()
        let service = NotificationService(provider: fake)
        let stream = service.actions()

        let result = service.handleResponseValues(
            categoryID: "biscotti.ad-hoc-detected",
            actionID: "biscotti.action.record",
            userInfo: [
                "biscotti.kind": "ad-hoc",
                "biscotti.bundleID": "us.zoom.xos"
            ]
        )

        #expect(result == true)

        var iterator = stream.makeAsyncIterator()
        let action = await iterator.next()
        #expect(action == .openAndRecord(eventKey: nil))
    }

    @Test("Keep Recording maps to keepRecording with meeting ID")
    @MainActor
    func keepRecordingActionMapsToKeepRecording() async {
        let fake = FakeNotificationCenter()
        let service = NotificationService(provider: fake)
        let stream = service.actions()

        let meetingID = UUID()
        let result = service.handleResponseValues(
            categoryID: "biscotti.stop-countdown",
            actionID: "biscotti.action.keep-recording",
            userInfo: [
                "biscotti.kind": "countdown",
                "biscotti.meetingID": meetingID.uuidString
            ]
        )

        #expect(result == true)

        var iterator = stream.makeAsyncIterator()
        let action = await iterator.next()
        #expect(action == .keepRecording(meetingID: meetingID))
    }

    @Test("Default action on meeting-start maps to openAndRecord")
    @MainActor
    func defaultActionOnMeetingStartMapsToOpenAndRecord() async {
        let fake = FakeNotificationCenter()
        let service = NotificationService(provider: fake)
        let stream = service.actions()

        let result = service.handleResponseValues(
            categoryID: "biscotti.meeting-starting",
            actionID: UNNotificationDefaultActionIdentifier,
            userInfo: [
                "biscotti.kind": "meeting-starting",
                "biscotti.eventKey": "ev-default"
            ]
        )

        #expect(result == true)

        var iterator = stream.makeAsyncIterator()
        let action = await iterator.next()
        #expect(action == .openAndRecord(eventKey: "ev-default"))
    }

    @Test("Default action on ad-hoc maps to openAndRecord with nil key")
    @MainActor
    func defaultActionOnAdHocMapsToOpenAndRecord() async {
        let fake = FakeNotificationCenter()
        let service = NotificationService(provider: fake)
        let stream = service.actions()

        let result = service.handleResponseValues(
            categoryID: "biscotti.ad-hoc-detected",
            actionID: UNNotificationDefaultActionIdentifier,
            userInfo: [
                "biscotti.kind": "ad-hoc",
                "biscotti.bundleID": "us.zoom.xos"
            ]
        )

        #expect(result == true)

        var iterator = stream.makeAsyncIterator()
        let action = await iterator.next()
        #expect(action == .openAndRecord(eventKey: nil))
    }

    @Test("Default action on countdown maps to keepRecording")
    @MainActor
    func defaultActionOnCountdownMapsToKeepRecording() async {
        let fake = FakeNotificationCenter()
        let service = NotificationService(provider: fake)
        let stream = service.actions()

        let meetingID = UUID()
        let result = service.handleResponseValues(
            categoryID: "biscotti.stop-countdown",
            actionID: UNNotificationDefaultActionIdentifier,
            userInfo: [
                "biscotti.kind": "countdown",
                "biscotti.meetingID": meetingID.uuidString
            ]
        )

        // Tapping the notification body triggers keepRecording (cancels
        // auto-stop and navigates to the recording screen).
        #expect(result == true)

        var iterator = stream.makeAsyncIterator()
        let action = await iterator.next()
        #expect(action == .keepRecording(meetingID: meetingID))
    }

    @Test("Dismiss action is not enqueued")
    @MainActor
    func dismissActionIsNotEnqueued() {
        let fake = FakeNotificationCenter()
        let service = NotificationService(provider: fake)

        let result = service.handleResponseValues(
            categoryID: "biscotti.meeting-starting",
            actionID: UNNotificationDismissActionIdentifier,
            userInfo: [
                "biscotti.kind": "meeting-starting",
                "biscotti.eventKey": "ev-dismiss"
            ]
        )

        #expect(result == false)
    }
}
