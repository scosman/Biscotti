import Foundation

/// Abstraction over EKEventStore for testability. All methods are synchronous or
/// async but never block callers on the main thread -- implementations run heavy
/// work off-main.
public protocol EventStoreProviding: Sendable {
    /// Returns the current calendar authorization status.
    func authorizationStatus() -> CalendarAuthStatus

    /// Requests full calendar access. Returns `true` if granted.
    func requestAccess() async throws -> Bool

    /// Returns all visible calendars.
    func calendars() -> [CalendarInfo]

    /// Synchronous fetch (EKEventStore.events(matching:) is blocking).
    /// Must be called off the main thread.
    /// - Parameters:
    ///   - interval: The date range to fetch events from.
    ///   - calendars: Calendar identifiers to filter by. `nil` = all calendars.
    func events(in interval: DateInterval, calendars: [String]?) -> [EKEventDTO]

    /// Re-validate a previously fetched event. Returns nil if deleted.
    func refreshEvent(eventIdentifier: String, occurrenceStart: Date) -> EKEventDTO?
}

// MARK: - EKEventDTO

/// Thin, Sendable mirror of EKEvent fields. No EKEvent reference retained.
/// Internal to the Calendar module for mapping; only `CalendarEvent` /
/// `CalendarSnapshotInput` cross the module boundary.
public struct EKEventDTO: Sendable, Equatable {
    public let eventIdentifier: String
    public let calendarItemIdentifier: String
    public let calendarItemExternalIdentifier: String
    public let occurrenceDate: Date

    public let title: String?
    public let startDate: Date
    public let endDate: Date
    public let isAllDay: Bool
    public let location: String?
    public let url: URL?
    public let timeZone: String?
    public let notes: String?
    public let status: String?
    public let availability: String?

    /// `EKCalendar.calendarIdentifier`
    public let calendarIdentifier: String
    public let calendarTitle: String
    public let calendarColorHex: String
    public let calendarSourceTitle: String

    /// Non-nil when the event is a birthday-calendar entry.
    public let birthdayContactIdentifier: String?

    public let attendeeCount: Int
    public let attendees: [AttendeeDTO]
    public let organizer: AttendeeDTO?

    public init(
        eventIdentifier: String,
        calendarItemIdentifier: String,
        calendarItemExternalIdentifier: String,
        occurrenceDate: Date,
        title: String?,
        startDate: Date,
        endDate: Date,
        isAllDay: Bool,
        location: String?,
        url: URL?,
        timeZone: String?,
        notes: String?,
        status: String?,
        availability: String?,
        calendarIdentifier: String,
        calendarTitle: String,
        calendarColorHex: String,
        calendarSourceTitle: String,
        birthdayContactIdentifier: String?,
        attendeeCount: Int,
        attendees: [AttendeeDTO],
        organizer: AttendeeDTO?
    ) {
        self.eventIdentifier = eventIdentifier
        self.calendarItemIdentifier = calendarItemIdentifier
        self.calendarItemExternalIdentifier = calendarItemExternalIdentifier
        self.occurrenceDate = occurrenceDate
        self.title = title
        self.startDate = startDate
        self.endDate = endDate
        self.isAllDay = isAllDay
        self.location = location
        self.url = url
        self.timeZone = timeZone
        self.notes = notes
        self.status = status
        self.availability = availability
        self.calendarIdentifier = calendarIdentifier
        self.calendarTitle = calendarTitle
        self.calendarColorHex = calendarColorHex
        self.calendarSourceTitle = calendarSourceTitle
        self.birthdayContactIdentifier = birthdayContactIdentifier
        self.attendeeCount = attendeeCount
        self.attendees = attendees
        self.organizer = organizer
    }
}

/// Sendable mirror of EKParticipant fields.
public struct AttendeeDTO: Sendable, Equatable {
    public let name: String?
    /// The raw participant URL (usually `mailto:someone@example.com`).
    public let participantURL: URL?
    public let isCurrentUser: Bool
    public let role: String
    public let status: String
    public let type: String

    public init(
        name: String?,
        participantURL: URL?,
        isCurrentUser: Bool,
        role: String,
        status: String,
        type: String
    ) {
        self.name = name
        self.participantURL = participantURL
        self.isCurrentUser = isCurrentUser
        self.role = role
        self.status = status
        self.type = type
    }
}
