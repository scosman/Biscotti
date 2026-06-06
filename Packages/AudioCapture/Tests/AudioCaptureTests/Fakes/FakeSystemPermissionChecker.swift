import Foundation
import Synchronization
@testable import AudioCapture

/// A fake `SystemPermissionChecker` that returns a canned result.
final class FakeSystemPermissionChecker: SystemPermissionChecker, @unchecked Sendable {
    private let denied = Mutex<Bool>(false)

    init(probableDenied: Bool = false) {
        denied.withLock { $0 = probableDenied }
    }

    func setProbableDenied(_ value: Bool) {
        denied.withLock { $0 = value }
    }

    func probableDenied() async -> Bool {
        denied.withLock { $0 }
    }
}
