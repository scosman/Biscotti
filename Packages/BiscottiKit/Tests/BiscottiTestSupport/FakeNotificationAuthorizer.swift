import Foundation
import Permissions

/// A configurable fake `NotificationAuthorizing` for tests.
///
/// Uses a reference-type backing store so mutations are visible through
/// protocol existentials. The backing store is `@unchecked Sendable` --
/// all access is confined to `@MainActor` test functions in practice.
public struct FakeNotificationAuthorizer: NotificationAuthorizing,
    @unchecked Sendable
{
    public final class Backing: @unchecked Sendable {
        public var currentStatus: PermissionState
        public var requestResult: Bool
        public var requestCalled = false

        public init(status: PermissionState, requestResult: Bool) {
            currentStatus = status
            self.requestResult = requestResult
        }
    }

    public let backing: Backing

    @MainActor
    public init(
        status: PermissionState = .notDetermined,
        requestResult: Bool = true
    ) {
        backing = Backing(status: status, requestResult: requestResult)
    }

    public func status() async -> PermissionState {
        backing.currentStatus
    }

    public func request() async -> Bool {
        backing.requestCalled = true
        return backing.requestResult
    }
}
