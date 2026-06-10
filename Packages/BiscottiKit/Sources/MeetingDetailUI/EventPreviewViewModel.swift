import AppCore
import Calendar
import Foundation

/// View model for the read-only preview of an upcoming calendar event.
///
/// Exposes event data and a record action, keeping `EventPreviewView` thin
/// per the view-model convention (every screen has one VM).
@MainActor @Observable
public final class EventPreviewViewModel {
    private let core: AppCore
    private let eventKey: String

    public init(core: AppCore, eventKey: String) {
        self.core = core
        self.eventKey = eventKey
    }

    /// The calendar event this preview displays. `nil` if the event was
    /// deleted between sidebar selection and detail render.
    public var event: CalendarEvent? {
        core.calendar.event(forKey: eventKey)
    }

    /// Whether the Record button should be disabled (recording already active).
    public var recordDisabled: Bool {
        core.recording.state.isRecording
    }

    /// Starts recording pre-associated with this event (C4 explicit key).
    public func startRecording() async {
        await core.startRecording(eventKey: eventKey)
    }
}
