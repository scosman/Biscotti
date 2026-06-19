import Foundation
import Synchronization
@testable import AudioCapture

/// A fake `SystemPermissionChecker` that returns canned results.
final class FakeSystemPermissionChecker: SystemPermissionChecker, @unchecked Sendable {
    private let denied = Mutex<Bool>(false)
    private let _observedNonZero = Mutex<Bool>(false)

    init(probableDenied: Bool = false, observedNonZero: Bool = false) {
        denied.withLock { $0 = probableDenied }
        _observedNonZero.withLock { $0 = observedNonZero }
    }

    func setProbableDenied(_ value: Bool) {
        denied.withLock { $0 = value }
    }

    func setObservedNonZero(_ value: Bool) {
        _observedNonZero.withLock { $0 = value }
    }

    var observedNonZero: Bool {
        _observedNonZero.withLock { $0 }
    }

    func probableDenied() async -> Bool {
        denied.withLock { $0 }
    }

    func reset() {
        denied.withLock { $0 = false }
        _observedNonZero.withLock { $0 = false }
    }
}
