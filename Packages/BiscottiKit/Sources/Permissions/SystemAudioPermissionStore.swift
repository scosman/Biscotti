import Foundation

/// Persistence seam for system-audio permission state.
///
/// The protocol exists so `Permissions` is unit-testable with an
/// in-memory fake. The production implementation uses `UserDefaults.standard`
/// (device-local, non-syncing) -- **never** SwiftData/`AppSettings` (those
/// sync via CloudKit; TCC grants are device-local).
public protocol SystemAudioPermissionStore: Sendable {
    func load() -> SystemAudioPermissionState
    func save(_ state: SystemAudioPermissionState)
}

/// Production store backed by `UserDefaults`.
///
/// This is the project's single `UserDefaults` usage. The key is
/// `"systemAudioPermissionState"`; the value is the raw string of the enum.
public struct UserDefaultsSystemAudioPermissionStore: SystemAudioPermissionStore, @unchecked Sendable {
    private let defaults: UserDefaults
    private let key = "systemAudioPermissionState"

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    public func load() -> SystemAudioPermissionState {
        defaults
            .string(forKey: key)
            .flatMap(SystemAudioPermissionState.init(rawValue:))
            ?? .notRequested
    }

    public func save(_ state: SystemAudioPermissionState) {
        defaults.set(state.rawValue, forKey: key)
    }
}
