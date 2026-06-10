import Foundation
import Permissions

/// A configurable fake `MicAuthorizing` for tests.
///
/// Uses a reference-type backing store so mutations are visible through
/// protocol existentials. The backing store is `@unchecked Sendable` --
/// all access is confined to `@MainActor` test functions in practice.
public struct FakeMicAuthorizer: MicAuthorizing, @unchecked Sendable {
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
    public init(status: PermissionState = .authorized, requestResult: Bool = true) {
        backing = Backing(status: status, requestResult: requestResult)
    }

    public func status() -> PermissionState {
        backing.currentStatus
    }

    public func request() async -> Bool {
        backing.requestCalled = true
        return backing.requestResult
    }
}
