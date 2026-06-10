import Foundation

// MARK: - Snapshot input (Sendable DTO for DataStore)

/// Built by CalendarService from an EKEventDTO; handed to AppCore, which calls
/// `DataStore.setSnapshot` + `setParticipants` with it. Keeps EventKit out of DataStore.
public struct CalendarSnapshotInput: Sendable, Equatable {
    // Link keys
    public let eventIdentifier: String
    public let calendarItemIdentifier: String
    public let calendarItemExternalIdentifier: String
    public let occurrenceStartDate: Date
    /// Human-readable fallback (title+start+organizer)
    public let compositeKey: String

    // Core fields
    public let title: String
    public let startDate: Date
    public let endDate: Date
    public let isAllDay: Bool
    public let location: String?
    public let url: URL?
    /// `TimeZone.identifier`
    public let timeZone: String?
    public let eventNotes: String
    public let status: String?
    public let availability: String?

    // Calendar provenance
    public let calendarTitle: String
    public let calendarColorHex: String?

    // Conferencing
    public let conferenceURL: URL?
    public let conferencePlatform: String?

    // Participants (Sendable value types)
    public let organizer: AttendeeInput?
    public let attendees: [AttendeeInput]

    public init(
        eventIdentifier: String,
        calendarItemIdentifier: String,
        calendarItemExternalIdentifier: String,
        occurrenceStartDate: Date,
        compositeKey: String,
        title: String,
        startDate: Date,
        endDate: Date,
        isAllDay: Bool,
        location: String?,
        url: URL?,
        timeZone: String?,
        eventNotes: String,
        status: String?,
        availability: String?,
        calendarTitle: String,
        calendarColorHex: String?,
        conferenceURL: URL?,
        conferencePlatform: String?,
        organizer: AttendeeInput?,
        attendees: [AttendeeInput]
    ) {
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
        self.organizer = organizer
        self.attendees = attendees
    }
}

/// A single attendee/organizer, mapped from an EKParticipant.
public struct AttendeeInput: Sendable, Equatable {
    public let name: String?
    /// Parsed from `mailto:` URL
    public let email: String?
    public let isCurrentUser: Bool
    public let role: String
    public let status: String
    public let type: String

    public init(
        name: String?,
        email: String?,
        isCurrentUser: Bool,
        role: String,
        status: String,
        type: String
    ) {
        self.name = name
        self.email = email
        self.isCurrentUser = isCurrentUser
        self.role = role
        self.status = status
        self.type = type
    }
}
