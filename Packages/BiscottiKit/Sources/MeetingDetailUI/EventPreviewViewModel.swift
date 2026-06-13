import AppCore
import Calendar
import Foundation

/// The primary call-to-action for the event preview, determined by
/// time relative to the event start and whether a conference URL exists.
public enum EventAction: Equatable, Sendable {
    /// Meeting is >15 min away and has a conference URL.
    case openLink
    /// Meeting is within +/-15 min of start and has a conference URL.
    case joinAndRecord
    /// No conference URL, or fallback manual record.
    case record
}

/// View model for the read-only preview of an upcoming calendar event.
///
/// Exposes event data, time-based action buttons, and all available
/// event details, keeping `EventPreviewView` thin per the view-model
/// convention (every screen has one VM).
@MainActor @Observable
public final class EventPreviewViewModel {
    private let core: AppCore
    private let eventKey: String

    /// Injectable "now" for deterministic tests.
    private let currentDate: () -> Date

    /// Injectable callback for opening URLs (set by the view/test).
    let urlOpener: (URL) -> Void

    /// The time window (in seconds) around the event start where
    /// "Join and Record" is the primary action. +/-15 minutes.
    static let joinWindowSeconds: TimeInterval = MeetingTiming.joinWindowSeconds

    public init(
        core: AppCore,
        eventKey: String,
        currentDate: @escaping () -> Date = { Date() },
        urlOpener: @escaping (URL) -> Void = { _ in }
    ) {
        self.core = core
        self.eventKey = eventKey
        self.currentDate = currentDate
        self.urlOpener = urlOpener
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

    /// The primary action button to show, based on time and conference URL.
    public var primaryAction: EventAction {
        guard let event else { return .record }
        guard event.conferenceURL != nil else { return .record }

        let now = currentDate()
        let secondsUntilStart = event.start.timeIntervalSince(now)

        // Within +/-15 min of start -> Join and Record
        if abs(secondsUntilStart) <= Self.joinWindowSeconds {
            return .joinAndRecord
        }

        // More than 15 min before start -> Open Link
        if secondsUntilStart > Self.joinWindowSeconds {
            return .openLink
        }

        // Past the +15 min window (meeting well underway) -> plain record
        return .record
    }

    /// Whether to show a secondary "Record" button alongside the primary.
    /// Shown when primary is openLink or joinAndRecord so the user always
    /// has a manual record option.
    public var showSecondaryRecord: Bool {
        primaryAction != .record
    }

    // MARK: - Actions

    /// Starts recording pre-associated with this event (C4 explicit key).
    public func startRecording() async {
        await core.startRecording(eventKey: eventKey)
    }

    /// Opens the conference URL without starting a recording.
    public func openLink() {
        guard let url = event?.conferenceURL else { return }
        urlOpener(url)
    }

    /// Opens the conference URL AND starts recording with the event key.
    public func joinAndRecord() async {
        if let url = event?.conferenceURL {
            urlOpener(url)
        }
        await core.startRecording(eventKey: eventKey)
    }
}
