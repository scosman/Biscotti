import Foundation
import Notifications
import Testing
import UserNotifications

@Suite("Foreground presentation")
struct ForegroundPresentationTests {
    @Test("Meeting-start shows banner without sound")
    @MainActor
    func foregroundMeetingStartShowsBannerWithoutSound() async throws {
        let fake = FakeNotificationCenter()
        let service = NotificationService(provider: fake)
        _ = await service.requestAuthorization()

        await service.present(
            .meetingStarting(eventKey: "k", title: "Standup", joinURL: nil)
        )

        let request = fake.addedRequests[0]
        let notification = try #require(UNNotification(
            coder: FakeNotificationCoder(request: request)
        ))
        let options = service.foregroundPresentationOptions(for: notification)
        #expect(options.contains(.banner))
        #expect(!options.contains(.sound))
    }

    @Test("Countdown shows banner without sound (only UI for Keep Recording)")
    @MainActor
    func foregroundCountdownShowsBannerWithoutSound() async throws {
        let fake = FakeNotificationCenter()
        let service = NotificationService(provider: fake)
        _ = await service.requestAuthorization()

        let meetingID = UUID()
        await service.present(
            .stopCountdown(meetingID: meetingID, secondsRemaining: 10)
        )

        let request = fake.addedRequests[0]
        let notification = try #require(UNNotification(
            coder: FakeNotificationCoder(request: request)
        ))
        let options = service.foregroundPresentationOptions(for: notification)
        #expect(options.contains(.banner))
        #expect(!options.contains(.sound))
    }
}

/// Minimal NSCoder subclass that lets us construct a `UNNotification` in tests.
///
/// `UNNotification` requires an NSCoder. We encode just enough for the
/// `categoryIdentifier` to round-trip through `foregroundPresentationOptions`.
private final class FakeNotificationCoder: NSCoder {
    private let request: UNNotificationRequest
    private var store: [String: Any] = [:]

    init(request: UNNotificationRequest) {
        self.request = request
        super.init()
        store["request"] = request
        store["date"] = Date()
    }

    override var allowsKeyedCoding: Bool {
        true
    }

    override func decodeObject(forKey key: String) -> Any? {
        store[key]
    }

    override func containsValue(forKey key: String) -> Bool {
        store[key] != nil
    }

    /// NSCoder requires these for UNNotification init
    override func decodeBool(forKey _: String) -> Bool {
        false
    }

    override func decodeInt64(forKey _: String) -> Int64 {
        0
    }

    override func decodeDouble(forKey _: String) -> Double {
        0
    }
}
