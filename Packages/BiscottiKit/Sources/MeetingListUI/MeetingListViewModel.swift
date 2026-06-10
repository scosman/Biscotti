import AppCore
import DataStore
import Foundation

/// View model for the sidebar's past-meetings list.
///
/// Reads `AppCore.summaries` and forwards selection to `AppCore.select(_:)`.
/// The view model is a thin projection -- all data lives in `AppCore`.
@MainActor @Observable
public final class MeetingListViewModel {
    private let core: AppCore

    /// The meetings to display, newest first.
    public var meetings: [MeetingSummary] {
        core.summaries
    }

    /// The currently selected meeting ID (derived from the route).
    public var selectedMeetingID: UUID? {
        if case let .meeting(id) = core.route {
            return id
        }
        return nil
    }

    public init(core: AppCore) {
        self.core = core
    }

    /// Called when the user selects a meeting in the list.
    public func select(_ meetingID: UUID) {
        core.select(meetingID)
    }

    private static let relativeDateFormatter: RelativeDateTimeFormatter = {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .abbreviated
        return formatter
    }()

    /// Formats a meeting date as a relative string for sidebar display.
    public static func relativeDate(_ date: Date) -> String {
        relativeDateFormatter.localizedString(for: date, relativeTo: Date())
    }
}
