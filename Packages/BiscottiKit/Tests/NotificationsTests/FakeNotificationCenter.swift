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
        var authRequestCount = 0
        var authorizationGranted = true
        var currentStatus: UNAuthorizationStatus = .authorized
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
    }

    func removePendingRequests(withIdentifiers ids: [String]) {
        backing.removedPendingIDs.append(ids)
    }

    func removeDeliveredNotifications(withIdentifiers ids: [String]) {
        backing.removedDeliveredIDs.append(ids)
    }

    func authorizationStatus() async -> UNAuthorizationStatus {
        backing.currentStatus
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
}
