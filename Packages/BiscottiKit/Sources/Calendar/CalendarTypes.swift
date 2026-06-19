import Foundation

// MARK: - Auth

/// Maps EKAuthorizationStatus to a simpler app-level enum.
/// `.writeOnly` and `.restricted` both map to `.denied` for read access purposes.
public enum CalendarAuthStatus: Sendable, Equatable {
    case notDetermined, authorized, denied, restricted
}

// MARK: - Calendar info (settings / onboarding UI)

/// Metadata about a single calendar, for the include/exclude selection UI.
public struct CalendarInfo: Sendable, Identifiable, Equatable {
    /// `EKCalendar.calendarIdentifier`
    public let id: String
    public let title: String
    /// `#RRGGBB` from cgColor; fallback `#808080`
    public let colorHex: String
    /// `EKSource.title`, for grouping in the UI
    public let sourceTitle: String

    public init(id: String, title: String, colorHex: String, sourceTitle: String) {
        self.id = id
        self.title = title
        self.colorHex = colorHex
        self.sourceTitle = sourceTitle
    }
}

// MARK: - Attendee info (live event surface)

/// A single attendee/organizer for a live calendar event.
/// Lighter than `AttendeeInput` (snapshot-level) -- just name + email for display.
public struct AttendeeInfo: Sendable, Equatable {
    public let name: String?
    public let email: String?

    public init(name: String?, email: String?) {
        self.name = name
        self.email = email
    }

    /// Display-friendly label: name if available, otherwise email, otherwise "Unknown".
    public var displayName: String {
        if let name, !name.isEmpty { return name }
        if let email, !email.isEmpty { return email }
        return "Unknown"
    }
}

// MARK: - Live event DTO

/// A live, un-recorded calendar event. Never holds an EKEvent reference.
public struct CalendarEvent: Sendable, Identifiable, Equatable {
    /// Composite key (see `CompositeKey.make`)
    public let id: String
    public let title: String
    public let start: Date
    public let end: Date
    public let conferencePlatform: String?
    public let conferenceURL: URL?
    public let attendeeCount: Int
    public let calendarTitle: String
    public let calendarColorHex: String
    /// `conferenceURL != nil || attendeeCount >= 2`
    public var isMeetingLike: Bool
    /// The event organizer, if known.
    public let organizer: AttendeeInfo?
    /// All attendees (excluding the organizer).
    public let attendees: [AttendeeInfo]
    /// The event's notes/description from the calendar.
    public let notes: String?
    /// The event's location string from the calendar.
    public let location: String?

    public init(
        id: String,
        title: String,
        start: Date,
        end: Date,
        conferencePlatform: String?,
        conferenceURL: URL?,
        attendeeCount: Int,
        calendarTitle: String,
        calendarColorHex: String,
        isMeetingLike: Bool,
        organizer: AttendeeInfo? = nil,
        attendees: [AttendeeInfo] = [],
        notes: String? = nil,
        location: String? = nil
    ) {
        self.id = id
        self.title = title
        self.start = start
        self.end = end
        self.conferencePlatform = conferencePlatform
        self.conferenceURL = conferenceURL
        self.attendeeCount = attendeeCount
        self.calendarTitle = calendarTitle
        self.calendarColorHex = calendarColorHex
        self.isMeetingLike = isMeetingLike
        self.organizer = organizer
        self.attendees = attendees
        self.notes = notes
        self.location = location
    }
}
