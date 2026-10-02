import Foundation
import Notifications
import Testing

// MARK: - cancelMeetingStarting / cancelAdHocDetected(bundleID:)

@Suite("Notification cleanup -- single cancel")
struct NotificationSingleCancelTests {
    @Test("cancelMeetingStarting removes the correct ID from pending and delivered")
    @MainActor
    func cancelMeetingStartingRemovesCorrectID() async {
        let fake = FakeNotificationCenter()
        let service = NotificationService(provider: fake)
        _ = await service.requestAuthorization()

        await service.present(
            .meetingStarting(
                eventKey: "ev-1", title: "Standup", joinURL: nil,
                start: Date()
            )
        )
        #expect(fake.addedRequests.count == 1)
        let expectedID = "biscotti.notif.meeting-start.ev-1"

        await service.cancelMeetingStarting(eventKey: "ev-1")

        #expect(fake.removedPendingIDs.last == [expectedID])
        #expect(fake.removedDeliveredIDs.last == [expectedID])
    }

    @Test("cancelAdHocDetected(bundleID:) removes single-app ID and drops from tracking")
    @MainActor
    func cancelAdHocBundleIDRemovesAndDrops() async {
        let fake = FakeNotificationCenter()
        let service = NotificationService(provider: fake)
        _ = await service.requestAuthorization()

        await service.present(
            .adHocDetected(bundleID: "us.zoom.xos", appName: "Zoom")
        )
        let expectedID = "biscotti.notif.adhoc.us.zoom.xos"

        await service.cancelAdHocDetected(bundleID: "us.zoom.xos")

        #expect(fake.removedPendingIDs.last == [expectedID])
        #expect(fake.removedDeliveredIDs.last == [expectedID])

        // The old bulk cancelAdHocDetected() should not include this ID
        // again (it was dropped from presentedAdHocIDs).
        let pendingCountBefore = fake.removedPendingIDs.count
        await service.cancelAdHocDetected()
        #expect(fake.removedPendingIDs.count == pendingCountBefore)
    }
}

// MARK: - cancelAllMeetingStarting

@Suite("Notification cleanup -- cancelAllMeetingStarting")
struct CancelAllMeetingStartingTests {
    @Test("removes all meeting-start delivered entries, leaves ad-hoc and countdown")
    @MainActor
    func removesOnlyMeetingStart() async {
        let fake = FakeNotificationCenter()
        let service = NotificationService(provider: fake)
        _ = await service.requestAuthorization()

        // Post a mix of notification kinds.
        await service.present(
            .meetingStarting(
                eventKey: "ev-1", title: "A", joinURL: nil,
                start: Date()
            )
        )
        await service.present(
            .meetingStarting(
                eventKey: "ev-2", title: "B", joinURL: nil,
                start: Date()
            )
        )
        await service.present(
            .adHocDetected(bundleID: "us.zoom.xos", appName: "Zoom")
        )
        await service.present(
            .stopCountdown(meetingID: UUID(), secondsRemaining: 10)
        )

        let removedBefore = fake.removedDeliveredIDs.count

        await service.cancelAllMeetingStarting()

        // Exactly one removal call with the two meeting-start IDs.
        #expect(fake.removedDeliveredIDs.count == removedBefore + 1)
        let removedIDs = Set(fake.removedDeliveredIDs.last ?? [])
        #expect(removedIDs.count == 2)
        #expect(removedIDs.contains("biscotti.notif.meeting-start.ev-1"))
        #expect(removedIDs.contains("biscotti.notif.meeting-start.ev-2"))
    }

    @Test("no remove calls when no meeting-start entries exist")
    @MainActor
    func noRemoveCallsWhenEmpty() async {
        let fake = FakeNotificationCenter()
        let service = NotificationService(provider: fake)
        _ = await service.requestAuthorization()

        // Only post an ad-hoc notification.
        await service.present(
            .adHocDetected(bundleID: "us.zoom.xos", appName: "Zoom")
        )

        let pendingBefore = fake.removedPendingIDs.count
        let deliveredBefore = fake.removedDeliveredIDs.count

        await service.cancelAllMeetingStarting()

        // No new removal calls.
        #expect(fake.removedPendingIDs.count == pendingBefore)
        #expect(fake.removedDeliveredIDs.count == deliveredBefore)
    }
}

// MARK: - Cancel runs regardless of authorization

@Suite("Notification cleanup -- authorization")
struct NotificationCleanupAuthorizationTests {
    @Test("cancel methods run when authorization is denied")
    @MainActor
    func cancelRunsWhenDenied() async {
        let fake = FakeNotificationCenter()
        fake.authorizationGranted = false
        fake.currentStatus = .denied
        let service = NotificationService(provider: fake)

        // Seed a delivered notification directly (present would skip due
        // to denied auth, so seed the fake's delivered list).
        fake.backing.delivered = [
            DeliveredNotification(
                identifier: "biscotti.notif.meeting-start.ev-1",
                date: Date(),
                userInfo: [
                    "biscotti.kind": "meeting-starting",
                    "biscotti.eventKey": "ev-1"
                ]
            )
        ]

        await service.cancelMeetingStarting(eventKey: "ev-1")
        #expect(!fake.removedPendingIDs.isEmpty)

        await service.cancelAdHocDetected(bundleID: "us.zoom.xos")
        #expect(fake.removedPendingIDs.count == 2)

        await service.cancelAllMeetingStarting()
        // The meeting-start was already removed from delivered by the
        // first cancel, so cancelAllMeetingStarting finds nothing. This
        // verifies it still executes (no early return on auth status).
    }
}

// MARK: - Content: eventStart in userInfo

@Suite("Notification cleanup -- eventStart userInfo")
struct EventStartUserInfoTests {
    @Test("meetingStarting request has eventStart in userInfo")
    @MainActor
    func eventStartInUserInfo() async {
        let fake = FakeNotificationCenter()
        let service = NotificationService(provider: fake)
        _ = await service.requestAuthorization()

        let start = Date(timeIntervalSince1970: 1_700_000_000)
        await service.present(
            .meetingStarting(
                eventKey: "k", title: "Test", joinURL: nil,
                start: start
            )
        )

        let content = fake.addedRequests[0].content
        let storedStart = content.userInfo["biscotti.eventStart"] as? String
        #expect(storedStart == String(start.timeIntervalSince1970))
    }
}

// MARK: - deliveredOfferNotifications parsing

@Suite("Notification cleanup -- deliveredOfferNotifications")
struct DeliveredOfferParsingTests {
    @Test("parses meeting-start with eventStart")
    @MainActor
    func parsesMeetingStartWithEventStart() async {
        let fake = FakeNotificationCenter()
        let service = NotificationService(provider: fake)

        let start = Date(timeIntervalSince1970: 1_700_000_000)
        fake.backing.delivered = [
            DeliveredNotification(
                identifier: "biscotti.notif.meeting-start.ev-1",
                date: Date(),
                userInfo: [
                    "biscotti.kind": "meeting-starting",
                    "biscotti.eventKey": "ev-1",
                    "biscotti.eventStart": String(
                        start.timeIntervalSince1970
                    )
                ]
            )
        ]

        let offers = await service.deliveredOfferNotifications()
        #expect(offers.count == 1)
        #expect(
            offers[0]
                == .meetingStarting(eventKey: "ev-1", meetingStart: start)
        )
    }

    @Test("parses meeting-start without eventStart (falls back to date)")
    @MainActor
    func parsesMeetingStartFallback() async {
        let fake = FakeNotificationCenter()
        let service = NotificationService(provider: fake)

        let deliveryDate = Date(timeIntervalSince1970: 1_700_000_100)
        fake.backing.delivered = [
            DeliveredNotification(
                identifier: "biscotti.notif.meeting-start.ev-old",
                date: deliveryDate,
                userInfo: [
                    "biscotti.kind": "meeting-starting",
                    "biscotti.eventKey": "ev-old"
                ]
            )
        ]

        let offers = await service.deliveredOfferNotifications()
        #expect(offers.count == 1)
        #expect(
            offers[0]
                == .meetingStarting(
                    eventKey: "ev-old", meetingStart: deliveryDate
                )
        )
    }

    @Test("parses ad-hoc")
    @MainActor
    func parsesAdHoc() async {
        let fake = FakeNotificationCenter()
        let service = NotificationService(provider: fake)

        fake.backing.delivered = [
            DeliveredNotification(
                identifier: "biscotti.notif.adhoc.us.zoom.xos",
                date: Date(),
                userInfo: [
                    "biscotti.kind": "ad-hoc",
                    "biscotti.bundleID": "us.zoom.xos"
                ]
            )
        ]

        let offers = await service.deliveredOfferNotifications()
        #expect(offers.count == 1)
        #expect(offers[0] == .adHocDetected(bundleID: "us.zoom.xos"))
    }

    @Test("skips countdown, unknown kind, and missing keys")
    @MainActor
    func skipsNonOffer() async {
        let fake = FakeNotificationCenter()
        let service = NotificationService(provider: fake)

        fake.backing.delivered = [
            // Countdown -- skipped
            DeliveredNotification(
                identifier: "biscotti.notif.countdown.xxx",
                date: Date(),
                userInfo: [
                    "biscotti.kind": "countdown",
                    "biscotti.meetingID": UUID().uuidString
                ]
            ),
            // Unknown kind -- skipped
            DeliveredNotification(
                identifier: "something",
                date: Date(),
                userInfo: ["biscotti.kind": "future-kind"]
            ),
            // Missing eventKey -- skipped
            DeliveredNotification(
                identifier: "biscotti.notif.meeting-start.broken",
                date: Date(),
                userInfo: ["biscotti.kind": "meeting-starting"]
            ),
            // Missing bundleID -- skipped
            DeliveredNotification(
                identifier: "biscotti.notif.adhoc.broken",
                date: Date(),
                userInfo: ["biscotti.kind": "ad-hoc"]
            )
        ]

        let offers = await service.deliveredOfferNotifications()
        #expect(offers.isEmpty)
    }
}
