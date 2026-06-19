/// Seam over calendar (EventKit) authorization.
///
/// The live implementation imports EventKit and wraps `EKEventStore`.
/// Tests inject a fake that returns scripted values. The protocol lives
/// in `Permissions` so the module stays free of EventKit imports.
public protocol CalendarAuthorizing: Sendable {
    /// Returns the current calendar authorization state.
    func status() -> PermissionState

    /// Requests calendar access. Returns the resulting state.
    func request() async -> PermissionState
}
