import EventKit
import Foundation

struct EventLinkKey: Codable, Hashable, Sendable {
    let eventIdentifier: String
    let calendarItemIdentifier: String
    let occurrenceStartDate: Date
}

struct AttendeeSnapshot: Codable, Hashable, Identifiable, Sendable {
    var id: String { "\(name ?? "unknown")-\(email ?? "noemail")-\(role)-\(status)-\(type)-\(isCurrentUser)" }

    var name: String?
    var email: String?
    /// The raw participant URL string, preserved for key generation when email is nil
    /// (e.g. Exchange X500 addresses that are not mailto: URLs).
    var participantURLString: String?
    var isCurrentUser: Bool
    var role: String
    var status: String
    var type: String

    /// Stable key for matching attendees across storage and lookup (e.g. enrichment dictionary).
    /// Uses email when available, falls back to participantURLString for non-mailto URLs.
    var enrichmentKey: String {
        let namePart = name ?? "unknown"
        let emailPart = email ?? participantURLString ?? "unknown"
        return "\(namePart)|\(emailPart)"
    }
}

struct CalendarEventSnapshot: Codable, Identifiable, Sendable {
    var id: String {
        let timestamp = Int64(linkKey.occurrenceStartDate.timeIntervalSince1970)
        return "\(linkKey.eventIdentifier)-\(timestamp)"
    }

    var linkKey: EventLinkKey
    var calendarItemExternalIdentifier: String

    var title: String
    var notes: String?
    var startDate: Date
    var endDate: Date
    var isAllDay: Bool
    var location: String?
    var url: URL?
    var timeZoneIdentifier: String?

    var availability: String
    var status: String

    var organizerName: String?
    var organizerEmail: String?
    var organizerIsCurrentUser: Bool

    var calendarIdentifier: String
    var calendarTitle: String
    var calendarColorHex: String?

    var attendees: [AttendeeSnapshot]

    var conferenceURL: URL?
    var conferencePlatform: String?

    var snapshotDate: Date
    /// When this snapshot was last verified against EventKit. Nil if never re-synced.
    var lastSyncDate: Date?
    /// True if the source event was deleted or could not be found during re-sync.
    var isStale: Bool
}

// MARK: - Email extraction

func emailFromParticipantURL(_ url: URL) -> String? {
    guard url.scheme == "mailto" else { return nil }
    guard let specifier = (url as NSURL).resourceSpecifier, !specifier.isEmpty else { return nil }
    return specifier
}

// MARK: - Participant role/status/type descriptions

func participantRoleDescription(_ role: EKParticipantRole) -> String {
    switch role {
    case .unknown: "unknown"
    case .required: "required"
    case .optional: "optional"
    case .chair: "chair"
    case .nonParticipant: "nonParticipant"
    @unknown default: "unknown(\(role.rawValue))"
    }
}

func participantStatusDescription(_ status: EKParticipantStatus) -> String {
    switch status {
    case .unknown: "unknown"
    case .pending: "pending"
    case .accepted: "accepted"
    case .declined: "declined"
    case .tentative: "tentative"
    case .delegated: "delegated"
    case .completed: "completed"
    case .inProcess: "inProcess"
    @unknown default: "unknown(\(status.rawValue))"
    }
}

func participantTypeDescription(_ type: EKParticipantType) -> String {
    switch type {
    case .unknown: "unknown"
    case .person: "person"
    case .room: "room"
    case .resource: "resource"
    case .group: "group"
    @unknown default: "unknown(\(type.rawValue))"
    }
}

func eventAvailabilityDescription(_ availability: EKEventAvailability) -> String {
    switch availability {
    case .notSupported: "notSupported"
    case .busy: "busy"
    case .free: "free"
    case .tentative: "tentative"
    case .unavailable: "unavailable"
    @unknown default: "unknown(\(availability.rawValue))"
    }
}

func eventStatusDescription(_ status: EKEventStatus) -> String {
    switch status {
    case .none: "none"
    case .confirmed: "confirmed"
    case .tentative: "tentative"
    case .canceled: "canceled"
    @unknown default: "unknown(\(status.rawValue))"
    }
}

// MARK: - Snapshot creation from EKEvent

func snapshotFromEvent(_ event: EKEvent) -> CalendarEventSnapshot {
    let linkKey = EventLinkKey(
        eventIdentifier: event.eventIdentifier,
        calendarItemIdentifier: event.calendarItemIdentifier,
        occurrenceStartDate: event.occurrenceDate
    )

    let attendeeSnapshots: [AttendeeSnapshot] = (event.attendees ?? []).map { participant in
        snapshotFromParticipant(participant)
    }

    let organizer = event.organizer
    let organizerEmail = organizer.flatMap { emailFromParticipantURL($0.url) }

    let conference = ConferenceDetector.detect(
        url: event.url,
        notes: event.notes,
        location: event.location
    )

    let calendarColorHex: String? = {
        guard let cgColor = event.calendar.cgColor else { return nil }
        guard let components = cgColor.components, components.count >= 1 else { return nil }
        let r: Int
        let g: Int
        let b: Int
        if components.count >= 3 {
            // RGB color space
            r = Int(components[0] * 255)
            g = Int(components[1] * 255)
            b = Int(components[2] * 255)
        } else {
            // Grayscale color space (gray + alpha): treat gray as all three channels
            let gray = Int(components[0] * 255)
            r = gray
            g = gray
            b = gray
        }
        return String(format: "#%02X%02X%02X", r, g, b)
    }()

    return CalendarEventSnapshot(
        linkKey: linkKey,
        calendarItemExternalIdentifier: event.calendarItemExternalIdentifier,
        title: event.title ?? "(No title)",
        notes: event.notes,
        startDate: event.startDate,
        endDate: event.endDate,
        isAllDay: event.isAllDay,
        location: event.location,
        url: event.url,
        timeZoneIdentifier: event.timeZone?.identifier,
        availability: eventAvailabilityDescription(event.availability),
        status: eventStatusDescription(event.status),
        organizerName: organizer?.name,
        organizerEmail: organizerEmail,
        organizerIsCurrentUser: organizer?.isCurrentUser ?? false,
        calendarIdentifier: event.calendar.calendarIdentifier,
        calendarTitle: event.calendar.title,
        calendarColorHex: calendarColorHex,
        attendees: attendeeSnapshots,
        conferenceURL: conference?.url,
        conferencePlatform: conference?.platform,
        snapshotDate: Date(),
        lastSyncDate: nil,
        isStale: false
    )
}

func snapshotFromParticipant(_ participant: EKParticipant) -> AttendeeSnapshot {
    AttendeeSnapshot(
        name: participant.name,
        email: emailFromParticipantURL(participant.url),
        participantURLString: participant.url.absoluteString,
        isCurrentUser: participant.isCurrentUser,
        role: participantRoleDescription(participant.participantRole),
        status: participantStatusDescription(participant.participantStatus),
        type: participantTypeDescription(participant.participantType)
    )
}
