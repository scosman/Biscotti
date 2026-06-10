import Foundation
import Permissions

/// Observable snapshot of the recording lifecycle for the UI.
public struct RecordingState: Sendable, Equatable {
    /// Whether a recording is currently in progress.
    public var isRecording: Bool
    /// Elapsed recording time in seconds.
    public var elapsed: TimeInterval
    /// The meeting ID for the current or most-recently-completed recording.
    public var meetingID: UUID?

    public init(isRecording: Bool, elapsed: TimeInterval, meetingID: UUID?) {
        self.isRecording = isRecording
        self.elapsed = elapsed
        self.meetingID = meetingID
    }

    /// The resting state before any recording.
    public static let idle = RecordingState(isRecording: false, elapsed: 0, meetingID: nil)
}

/// Errors surfaced by `RecordingController`.
public enum RecordingError: Error, Sendable, Equatable {
    /// A required permission was denied (mic or system audio).
    case permissionDenied(PermissionKind)
    /// The capture engine failed to start or threw during recording.
    case engineFailed(String)
    /// A persistence or storage operation failed (meeting creation, directory setup, audio ref attachment).
    case storageFailed(String)
    /// A recording is already in progress.
    case alreadyRecording
}
