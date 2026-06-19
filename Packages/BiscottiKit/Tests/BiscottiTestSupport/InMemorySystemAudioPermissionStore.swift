import Permissions

/// In-memory fake for `SystemAudioPermissionStore`. Used by test fixtures
/// to avoid touching real `UserDefaults`.
public final class InMemorySystemAudioPermissionStore: SystemAudioPermissionStore, @unchecked Sendable {
    private var stored: SystemAudioPermissionState = .notRequested

    public init() {}

    public func load() -> SystemAudioPermissionState {
        stored
    }

    public func save(_ state: SystemAudioPermissionState) {
        stored = state
    }
}
