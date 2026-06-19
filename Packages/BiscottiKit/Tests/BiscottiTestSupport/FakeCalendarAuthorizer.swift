import Foundation
import Permissions

/// A configurable fake `CalendarAuthorizing` for tests.
///
/// Uses a reference-type backing store so mutations are visible through
/// protocol existentials. The backing store is `@unchecked Sendable` --
/// all access is confined to `@MainActor` test functions in practice.
public struct FakeCalendarAuthorizer: CalendarAuthorizing,
    @unchecked Sendable
{
    public final class Backing: @unchecked Sendable {
        public var currentStatus: PermissionState
        public var requestResult: PermissionState
        public var requestCalled = false

        public init(
            status: PermissionState,
            requestResult: PermissionState
        ) {
            currentStatus = status
            self.requestResult = requestResult
        }
    }

    public let backing: Backing

    @MainActor
    public init(
        status: PermissionState = .notDetermined,
        requestResult: PermissionState = .authorized
    ) {
        backing = Backing(status: status, requestResult: requestResult)
    }

    public func status() -> PermissionState {
        backing.currentStatus
    }

    public func request() async -> PermissionState {
        backing.requestCalled = true
        backing.currentStatus = backing.requestResult
        return backing.requestResult
    }
}
