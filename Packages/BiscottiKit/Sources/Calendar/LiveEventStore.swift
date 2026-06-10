import EventKit
import Foundation

/// Production implementation of `EventStoreProviding` backed by a real `EKEventStore`.
///
/// Holds a strong reference to the store for the app's lifetime so
/// `.EKEventStoreChanged` fires. Maps EKEvent fields to `EKEventDTO` promptly,
/// releasing the EKEvent reference before returning.
public final class LiveEventStore: EventStoreProviding, @unchecked Sendable {
    /// The underlying EventKit store. Accessed only from `queue`.
    private let store = EKEventStore()

    /// Serializes all EKEventStore access off the main thread.
    private let queue = DispatchQueue(label: "net.scosman.biscotti.LiveEventStore")

    public init() {}

    // MARK: - EventStoreProviding

    public func authorizationStatus() -> CalendarAuthStatus {
        Self.mapStatus(EKEventStore.authorizationStatus(for: .event))
    }

    public func requestAccess() async throws -> Bool {
        try await store.requestFullAccessToEvents()
    }

    public func calendars() -> [CalendarInfo] {
        queue.sync {
            store.calendars(for: .event).map { cal in
                CalendarInfo(
                    id: cal.calendarIdentifier,
                    title: cal.title,
                    colorHex: Self.colorHex(from: cal.cgColor),
                    sourceTitle: cal.source?.title ?? ""
                )
            }
        }
    }

    public func events(
        in interval: DateInterval,
        calendars calendarIDs: [String]?
    ) -> [EKEventDTO] {
        queue.sync {
            let ekCalendars: [EKCalendar]? = calendarIDs.map { ids in
                let allCalendars = store.calendars(for: .event)
                return allCalendars.filter { ids.contains($0.calendarIdentifier) }
            }
            let predicate = store.predicateForEvents(
                withStart: interval.start,
                end: interval.end,
                calendars: ekCalendars
            )
            let events = store.events(matching: predicate)
            return events.map { Self.mapEvent($0) }
        }
    }

    public func refreshEvent(
        eventIdentifier: String,
        occurrenceStart: Date
    ) -> EKEventDTO? {
        queue.sync {
            guard let event = store.event(withIdentifier: eventIdentifier) else {
                return nil
            }
            // For recurring events, verify the occurrence date matches
            if abs(event.occurrenceDate.timeIntervalSince(occurrenceStart)) > 1 {
                return nil
            }
            return Self.mapEvent(event)
        }
    }

    // MARK: - Mapping helpers

    static func mapStatus(_ ekStatus: EKAuthorizationStatus) -> CalendarAuthStatus {
        switch ekStatus {
        case .notDetermined:
            .notDetermined
        case .fullAccess, .authorized:
            .authorized
        case .writeOnly:
            .denied
        case .denied:
            .denied
        case .restricted:
            .restricted
        @unknown default:
            .denied
        }
    }

    static func mapEvent(_ event: EKEvent) -> EKEventDTO {
        let attendeeDTOs = (event.attendees ?? []).map { mapParticipant($0) }
        let organizerDTO = event.organizer.map { mapParticipant($0) }

        return EKEventDTO(
            eventIdentifier: event.eventIdentifier,
            calendarItemIdentifier: event.calendarItemIdentifier,
            calendarItemExternalIdentifier: event.calendarItemExternalIdentifier,
            occurrenceDate: event.occurrenceDate,
            title: event.title,
            startDate: event.startDate,
            endDate: event.endDate,
            isAllDay: event.isAllDay,
            location: event.location,
            url: event.url,
            timeZone: event.timeZone?.identifier,
            notes: event.notes,
            status: eventStatusDescription(event.status),
            availability: eventAvailabilityDescription(event.availability),
            calendarIdentifier: event.calendar.calendarIdentifier,
            calendarTitle: event.calendar.title,
            calendarColorHex: colorHex(from: event.calendar.cgColor),
            calendarSourceTitle: event.calendar.source?.title ?? "",
            birthdayContactIdentifier: event.birthdayContactIdentifier,
            attendeeCount: event.attendees?.count ?? 0,
            attendees: attendeeDTOs,
            organizer: organizerDTO
        )
    }

    static func mapParticipant(_ participant: EKParticipant) -> AttendeeDTO {
        AttendeeDTO(
            name: participant.name,
            participantURL: participant.url,
            isCurrentUser: participant.isCurrentUser,
            role: participantRoleDescription(participant.participantRole),
            status: participantStatusDescription(participant.participantStatus),
            type: participantTypeDescription(participant.participantType)
        )
    }

    // MARK: - Color hex conversion

    static func colorHex(from cgColor: CGColor?) -> String {
        guard let cgColor, let components = cgColor.components,
              !components.isEmpty
        else {
            return "#808080"
        }
        let red: Int
        let green: Int
        let blue: Int
        if components.count >= 3 {
            red = Int(components[0] * 255)
            green = Int(components[1] * 255)
            blue = Int(components[2] * 255)
        } else {
            // Grayscale color space
            let gray = Int(components[0] * 255)
            red = gray
            green = gray
            blue = gray
        }
        return String(format: "#%02X%02X%02X", red, green, blue)
    }

    // MARK: - EventKit enum descriptions (productionized from EventKitLab)

    private static func eventStatusDescription(
        _ status: EKEventStatus
    ) -> String {
        switch status {
        case .none: "none"
        case .confirmed: "confirmed"
        case .tentative: "tentative"
        case .canceled: "canceled"
        @unknown default: "unknown(\(status.rawValue))"
        }
    }

    private static func eventAvailabilityDescription(
        _ availability: EKEventAvailability
    ) -> String {
        switch availability {
        case .notSupported: "notSupported"
        case .busy: "busy"
        case .free: "free"
        case .tentative: "tentative"
        case .unavailable: "unavailable"
        @unknown default: "unknown(\(availability.rawValue))"
        }
    }

    private static func participantRoleDescription(
        _ role: EKParticipantRole
    ) -> String {
        switch role {
        case .unknown: "unknown"
        case .required: "required"
        case .optional: "optional"
        case .chair: "chair"
        case .nonParticipant: "nonParticipant"
        @unknown default: "unknown(\(role.rawValue))"
        }
    }

    private static func participantStatusDescription(
        _ status: EKParticipantStatus
    ) -> String {
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

    private static func participantTypeDescription(
        _ type: EKParticipantType
    ) -> String {
        switch type {
        case .unknown: "unknown"
        case .person: "person"
        case .room: "room"
        case .resource: "resource"
        case .group: "group"
        @unknown default: "unknown(\(type.rawValue))"
        }
    }
}
