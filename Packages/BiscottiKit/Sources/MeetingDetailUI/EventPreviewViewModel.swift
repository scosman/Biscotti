import AppCore
import AppKit
import Calendar
import DesignSystem
import Foundation

/// The primary call-to-action for the event preview, determined by
/// whether a conference URL exists. The button *style* (prominent vs.
/// quiet) is gated by `isProminent`, not this enum.
public enum EventAction: Equatable, Sendable {
    /// Has a conference URL: primary = "Join & Record", secondary = "Copy Link".
    case joinAndRecord
    /// No conference URL: primary = "Record" only.
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

    /// Injectable clipboard writer for "Copy Link". Returns the string
    /// that was written so tests can verify without touching NSPasteboard.
    let clipboardWriter: (String) -> Void

    /// How early (in seconds) before event start actions become prominent.
    /// 5 minutes before start.
    static let prominenceLeadSeconds: TimeInterval = 5 * 60

    /// How late (in seconds) after event end actions stay prominent.
    /// 5 minutes after end.
    static let prominenceTrailSeconds: TimeInterval = 5 * 60

    public init(
        core: AppCore,
        eventKey: String,
        currentDate: @escaping () -> Date = { Date() },
        urlOpener: @escaping (URL) -> Void = { _ in },
        clipboardWriter: @escaping (String) -> Void = { text in
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(text, forType: .string)
        }
    ) {
        self.core = core
        self.eventKey = eventKey
        self.currentDate = currentDate
        self.urlOpener = urlOpener
        self.clipboardWriter = clipboardWriter
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

    // MARK: - Action & Prominence

    /// The primary action type based on whether a conference URL exists.
    public var primaryAction: EventAction {
        guard let event else { return .record }
        guard event.conferenceURL != nil else { return .record }
        return .joinAndRecord
    }

    /// Whether actions should be visually prominent (filled/accent buttons).
    /// True when the current time is within the prominence window:
    /// 5 min before start through 5 min after end.
    public var isProminent: Bool {
        guard let event else { return false }
        let now = currentDate()
        let windowStart = event.start.addingTimeInterval(-Self.prominenceLeadSeconds)
        let windowEnd = event.end.addingTimeInterval(Self.prominenceTrailSeconds)
        return now >= windowStart && now <= windowEnd
    }

    /// Whether to show the "Copy Link" button.
    /// Only when there is a conference URL.
    public var showCopyLink: Bool {
        event?.conferenceURL != nil
    }

    // MARK: - Display helpers

    /// Relative countdown text: "in 12m", "in 1h 30m", "now".
    public var relativeTimeText: String {
        guard let event else { return "" }
        return TimeFormatting.coarseRelativeTimeText(
            event.start, relativeTo: currentDate()
        )
    }

    /// Formatted date range: "Mon, Jun 11 · 4:18 - 4:50 PM".
    public var formattedDateRange: String? {
        guard let event else { return nil }
        return TimeFormatting.whenText(start: event.start, end: event.end)
    }

    /// Duration text: "1h", "30m".
    public var formattedDuration: String? {
        guard let event else { return nil }
        let seconds = event.end.timeIntervalSince(event.start)
        guard seconds > 0 else { return nil }
        return TimeFormatting.compactDuration(seconds)
    }

    /// Avatar data for the attendee cluster (organizer first, then attendees).
    public var avatarData: (people: [AvatarPerson], total: Int) {
        guard let event else { return ([], 0) }
        var people: [AvatarPerson] = []
        if let org = event.organizer {
            people.append(AvatarPerson(
                displayName: org.displayName, email: org.email
            ))
        }
        for att in event.attendees {
            people.append(AvatarPerson(
                displayName: att.displayName, email: att.email
            ))
        }
        return (people, event.attendeeCount)
    }

    /// Attendee email list for the expanded attendee section.
    /// Uses email when available, falls back to display name.
    public var attendeeEmailLines: [String] {
        guard let event else { return [] }
        var lines: [String] = []

        if let org = event.organizer {
            let label = org.email ?? org.displayName
            lines.append("\(label) (organizer)")
        }

        for att in event.attendees {
            lines.append(att.email ?? att.displayName)
        }

        return lines
    }

    /// Builds a domain summary like "6 from waldo.fyi · 2 from kiln.tech"
    /// from attendee emails. Returns nil when there are 0 or 1 distinct
    /// domains (no summary needed).
    public var domainSummary: String? {
        Self.buildDomainSummary(for: attendeeEmailLines)
    }

    /// Testable domain-summary builder. Extracts email domains from a
    /// list of lines (each may be "user@domain" or a display-name
    /// fallback), counts occurrences, and returns nil when <= 1 distinct
    /// domain is present.
    static func buildDomainSummary(for lines: [String]) -> String? {
        var counts: [String: Int] = [:]
        for line in lines {
            // Strip "(organizer)" suffix before extracting domain
            let cleaned = line.replacingOccurrences(
                of: " (organizer)", with: ""
            )
            guard let atIndex = cleaned.lastIndex(of: "@") else { continue }
            let domain = String(cleaned[cleaned.index(after: atIndex)...])
                .lowercased()
            guard !domain.isEmpty else { continue }
            counts[domain, default: 0] += 1
        }

        guard counts.count > 1 else { return nil }

        let sorted = counts.sorted {
            $0.value != $1.value ? $0.value > $1.value : $0.key < $1.key
        }
        let parts = sorted.map { "\($0.value) from \($0.key)" }
        return parts.joined(separator: " \u{00B7} ")
    }

    // MARK: - Actions

    /// Starts recording pre-associated with this event (C4 explicit key).
    public func startRecording() async {
        await core.startRecording(eventKey: eventKey)
    }

    /// Copies the conference URL to the clipboard.
    public func copyLink() {
        guard let url = event?.conferenceURL else { return }
        clipboardWriter(url.absoluteString)
    }

    /// Opens the conference URL AND starts recording with the event key.
    public func joinAndRecord() async {
        if let url = event?.conferenceURL {
            urlOpener(url)
        }
        await core.startRecording(eventKey: eventKey)
    }

    /// Opens the linked calendar event in Calendar.app via the shared
    /// `CalendarDeepLink` helper.
    public func openInCalendar() {
        guard let event else { return }

        // The composite key format is "eventIdentifier|calendarItemIdentifier|timestamp".
        // Extract the EKEvent identifier (first component) for the ical deep-link.
        let eventID = event.id.components(separatedBy: "|").first

        if let url = CalendarDeepLink.calendarAppURL(
            eventIdentifier: eventID,
            startDate: event.start
        ) {
            urlOpener(url)
        }
    }
}
