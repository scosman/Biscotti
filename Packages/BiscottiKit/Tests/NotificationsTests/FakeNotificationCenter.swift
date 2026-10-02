import Foundation
import Notifications
import UserNotifications

/// A fake `NotificationCenterProviding` for tests.
///
/// Records every call with arguments so tests can assert on categories registered,
/// requests added, and removal calls made. Authorization behavior is scriptable.
///
/// All mutable state lives in a reference-type `Backing` store marked
/// `@unchecked Sendable`. All tests run on `@MainActor` so there are no real
/// data races; the `@unchecked` annotation appeases Swift 6 strict concurrency.
final class FakeNotificationCenter: NotificationCenterProviding, @unchecked Sendable {
    /// Reference-type backing so mutations are visible through value copies.
    final class Backing: @unchecked Sendable {
        var setCategoriesCalls: [Set<UNNotificationCategory>] = []
        var addedRequests: [UNNotificationRequest] = []
        var removedPendingIDs: [[String]] = []
        var removedDeliveredIDs: [[String]] = []
        var delivered: [DeliveredNotification] = []
        var authRequestCount = 0
        var authorizationGranted = true
        var currentStatus: UNAuthorizationStatus = .authorized
        var scriptedAlertStyle: UNAlertStyle = .banner
    }

    let backing = Backing()

    // MARK: - Protocol conformance

    func requestAuthorization() async throws -> Bool {
        backing.authRequestCount += 1
        return backing.authorizationGranted
    }

    func setCategories(_ categories: Set<UNNotificationCategory>) {
        backing.setCategoriesCalls.append(categories)
    }

    func add(_ request: UNNotificationRequest) async throws {
        backing.addedRequests.append(request)
        // Model delivery: replace any existing entry with the same identifier.
        backing.delivered.removeAll { $0.identifier == request.identifier }
        var stringInfo: [String: String] = [:]
        for (key, value) in request.content.userInfo {
            if let strKey = key as? String, let strVal = value as? String {
                stringInfo[strKey] = strVal
            }
        }
        backing.delivered.append(DeliveredNotification(
            identifier: request.identifier,
            date: Date(),
            userInfo: stringInfo
        ))
    }

    func removePendingRequests(withIdentifiers ids: [String]) {
        backing.removedPendingIDs.append(ids)
    }

    func removeDeliveredNotifications(withIdentifiers ids: [String]) {
        backing.removedDeliveredIDs.append(ids)
        let idSet = Set(ids)
        backing.delivered.removeAll { idSet.contains($0.identifier) }
    }

    func deliveredNotifications() async -> [DeliveredNotification] {
        backing.delivered
    }

    func authorizationStatus() async -> UNAuthorizationStatus {
        backing.currentStatus
    }

    func alertStyle() async -> UNAlertStyle {
        backing.scriptedAlertStyle
    }

    // MARK: - Test accessors

    var setCategoriesCalls: [Set<UNNotificationCategory>] {
        backing.setCategoriesCalls
    }

    var addedRequests: [UNNotificationRequest] {
        backing.addedRequests
    }

    var removedPendingIDs: [[String]] {
        backing.removedPendingIDs
    }

    var removedDeliveredIDs: [[String]] {
        backing.removedDeliveredIDs
    }

    var authorizationGranted: Bool {
        get { backing.authorizationGranted }
        set { backing.authorizationGranted = newValue }
    }

    var currentStatus: UNAuthorizationStatus {
        get { backing.currentStatus }
        set { backing.currentStatus = newValue }
    }

    var scriptedAlertStyle: UNAlertStyle {
        get { backing.scriptedAlertStyle }
        set { backing.scriptedAlertStyle = newValue }
    }
}
