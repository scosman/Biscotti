import Foundation
import SwiftData

// MARK: - CalendarSnapshot

/// A frozen copy of calendar event metadata, clearable in one operation.
/// Participants + organizer are `Person` relationships on `Meeting` (dedup + voiceprints),
/// NOT frozen here.
@Model public final class CalendarSnapshot: @unchecked Sendable {
    #Unique<CalendarSnapshot>([\.id])

    public var id: UUID

    // MARK: Link keys (recurring-event-robust re-sync)

    /// EventKit id (shared across occurrences; may change on sync).
    public var eventIdentifier: String?
    /// Local-store id.
    public var calendarItemIdentifier: String?
    /// Cross-device id.
    public var calendarItemExternalIdentifier: String?
    /// Disambiguates a recurring instance.
    public var occurrenceStartDate: Date?
    /// Human fallback re-link key (title+start+organizer).
    public var compositeKey: String

    // MARK: Core event fields (copied at pairing time)

    public var title: String
    public var startDate: Date?
    public var endDate: Date?
    public var isAllDay: Bool
    /// Plain-text location (may hold a join URL).
    public var location: String?
    /// Event URL (sometimes the join link).
    public var url: URL?
    /// `TimeZone.identifier` string.
    public var timeZone: String?
    /// The EVENT's description (distinct from `Meeting.notes`).
    public var eventNotes: String
    /// `EKEventStatus` as a string (e.g. "canceled").
    public var status: String?
    /// `EKEventAvailability` as a string.
    public var availability: String?

    // MARK: Calendar provenance

    public var calendarTitle: String?
    public var calendarColorHex: String?

    // MARK: Conferencing (regex-extracted from notes/location/url)

    public var conferenceURL: URL?
    /// Platform identifier, e.g. "zoom", "meet", "teams".
    public var conferencePlatform: String?

    // MARK: Metadata

    /// When this snapshot was captured.
    public var snapshotDate: Date
    /// Source event deleted / not found on last sync.
    public var isStale: Bool

    public init(
        id: UUID = UUID(),
        eventIdentifier: String? = nil,
        calendarItemIdentifier: String? = nil,
        calendarItemExternalIdentifier: String? = nil,
        occurrenceStartDate: Date? = nil,
        compositeKey: String,
        title: String,
        startDate: Date? = nil,
        endDate: Date? = nil,
        isAllDay: Bool = false,
        location: String? = nil,
        url: URL? = nil,
        timeZone: String? = nil,
        eventNotes: String = "",
        status: String? = nil,
        availability: String? = nil,
        calendarTitle: String? = nil,
        calendarColorHex: String? = nil,
        conferenceURL: URL? = nil,
        conferencePlatform: String? = nil,
        snapshotDate: Date = Date(),
        isStale: Bool = false
    ) {
        self.id = id
        self.eventIdentifier = eventIdentifier
        self.calendarItemIdentifier = calendarItemIdentifier
        self.calendarItemExternalIdentifier = calendarItemExternalIdentifier
        self.occurrenceStartDate = occurrenceStartDate
        self.compositeKey = compositeKey
        self.title = title
        self.startDate = startDate
        self.endDate = endDate
        self.isAllDay = isAllDay
        self.location = location
        self.url = url
        self.timeZone = timeZone
        self.eventNotes = eventNotes
        self.status = status
        self.availability = availability
        self.calendarTitle = calendarTitle
        self.calendarColorHex = calendarColorHex
        self.conferenceURL = conferenceURL
        self.conferencePlatform = conferencePlatform
        self.snapshotDate = snapshotDate
        self.isStale = isStale
    }
}
