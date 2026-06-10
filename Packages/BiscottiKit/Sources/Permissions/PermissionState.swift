/// The authorization state of a system permission.
public enum PermissionState: Sendable, Equatable {
    case notDetermined
    case authorized
    case denied
}

/// The kinds of permissions the app requires.
public enum PermissionKind: Sendable {
    case microphone
    case systemAudio
    case calendar
    case notifications
}
