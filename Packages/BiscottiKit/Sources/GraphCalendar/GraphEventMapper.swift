import Calendar
import Foundation
import MeetingCatalog

/// The signed-in Microsoft 365 account: who "me" is for `isCurrentUser`,
/// and the label calendars are grouped under.
public struct GraphAccount: Sendable, Equatable {
    public let userPrincipalName: String
    public let mail: String?

    public init(userPrincipalName: String, mail: String?) {
        self.userPrincipalName = userPrincipalName
        self.mail = mail
    }

    public init(user: Graph.User) {
        self.init(userPrincipalName: user.userPrincipalName, mail: user.mail)
    }

    /// `CalendarInfo.sourceTitle` / `EKEventDTO.calendarSourceTitle`, e.g.
    /// "Microsoft 365 (jane@synderys.com)".
    public var sourceTitle: String {
        "Microsoft 365 (\(userPrincipalName))"
    }

    /// Case-insensitive match against the account's mail and UPN.
    public func isCurrentUser(address: String?) -> Bool {
        guard let address = address?.trimmingCharacters(in: .whitespaces).lowercased(),
              !address.isEmpty
        else { return false }
        return address == userPrincipalName.lowercased() || address == mail?.lowercased()
    }
}

/// Maps Graph calendars and events to the `Calendar` module's DTOs, so
/// `CalendarService` handles Microsoft 365 events exactly like EventKit
/// ones. Field mapping: `specs/projects/o365_calendar/functional_spec.md`
/// §4.
public struct GraphEventMapper: Sendable {
    public let account: GraphAccount
    public let catalog: any MeetingCatalog
    /// Zone all-day events are pinned to (EventKit shows them as local,
    /// floating days).
    public let localTimeZone: TimeZone
    public let notesLimit: Int

    public init(
        account: GraphAccount,
        catalog: any MeetingCatalog = BundledMeetingCatalog(),
        localTimeZone: TimeZone = .current,
        notesLimit: Int = HTMLText.defaultLimit
    ) {
        self.account = account
        self.catalog = catalog
        self.localTimeZone = localTimeZone
        self.notesLimit = notesLimit
    }

    // MARK: - Calendars

    public func calendarInfo(_ calendar: Graph.Calendar) -> CalendarInfo {
        CalendarInfo(
            id: calendar.id,
            title: calendarTitle(calendar),
            colorHex: Self.normalizedHex(calendar.hexColor),
            sourceTitle: account.sourceTitle
        )
    }

    /// Shared and delegated calendars are usually all named "Calendar", so
    /// they carry their owner: "Calendar (Pat Smith)".
    private func calendarTitle(_ calendar: Graph.Calendar) -> String {
        guard let owner = calendar.owner, let address = owner.address?.nonBlank,
              !account.isCurrentUser(address: address)
        else { return calendar.name }
        return "\(calendar.name) (\(owner.name?.nonBlank ?? address))"
    }

    /// `#RRGGBB` uppercased, or `#808080` (the EventKit fallback) when Graph
    /// sends an empty or malformed color.
    static func normalizedHex(_ value: String?) -> String {
        guard var hex = value?.trimmingCharacters(in: .whitespaces) else { return "#808080" }
        if hex.hasPrefix("#") {
            hex.removeFirst()
        }
        guard hex.count == 6, hex.allSatisfy(\.isHexDigit) else { return "#808080" }
        return "#" + hex.uppercased()
    }

    // MARK: - Events

    public func event(_ event: Graph.Event, calendar: CalendarInfo) throws -> EKEventDTO {
        let isAllDay = event.isAllDay ?? false
        let eventZone = event.originalStartTimeZone.flatMap(GraphDateParsing.timeZone(named:))
        let start: Date
        let end: Date
        let occurrenceDate: Date
        if isAllDay {
            start = try GraphDateParsing.startOfDay(from: event.start, eventZone: eventZone, in: localTimeZone)
            end = try GraphDateParsing.startOfDay(from: event.end, eventZone: eventZone, in: localTimeZone)
            occurrenceDate = start
        } else {
            start = try GraphDateParsing.date(from: event.start)
            end = try GraphDateParsing.date(from: event.end)
            occurrenceDate = GraphDateParsing.offsetDate(event.originalStart) ?? start
        }

        let location = event.location?.displayName?.nonBlank
        let bodyText = Self.bodyText(event.body)
        let url = joinURL(event, bodyText: bodyText)
        let notes = bodyText.map { HTMLText.plainText(fromText: $0, limit: notesLimit) }?.nonBlank

        let attendees = (event.attendees ?? []).map(attendeeDTO)
        let organizer = event.organizer?.emailAddress.map(organizerDTO)
        let organizerListed = organizer.map { organizer in
            attendees.contains { Self.sameAddress($0.participantURL, organizer.participantURL) }
        } ?? false
        // EventKit counts the organizer among attendees for invitations; a
        // Graph event lists invitees only. A plain appointment (no
        // invitees) counts 0, as in EventKit.
        let attendeeCount = attendees.isEmpty ? 0 : attendees.count + (organizer != nil && !organizerListed ? 1 : 0)

        return EKEventDTO(
            eventIdentifier: event.id,
            calendarItemIdentifier: event.seriesMasterId ?? event.id,
            calendarItemExternalIdentifier: event.iCalUId ?? "",
            occurrenceDate: occurrenceDate,
            title: event.subject?.nonBlank,
            startDate: start,
            endDate: end,
            isAllDay: isAllDay,
            location: location,
            url: url,
            timeZone: isAllDay ? nil : eventZone?.identifier,
            notes: notes,
            status: event.isCancelled == true ? "canceled" : event.responseStatus?.response,
            availability: event.showAs,
            calendarIdentifier: calendar.id,
            calendarTitle: calendar.title,
            calendarColorHex: calendar.colorHex,
            calendarSourceTitle: calendar.sourceTitle,
            birthdayContactIdentifier: nil,
            attendeeCount: attendeeCount,
            attendees: attendees,
            organizer: organizer
        )
    }

    /// The join link Graph reports, else the first conference link in the
    /// body. The body is searched before capping: Teams puts its link at
    /// the end.
    private func joinURL(_ event: Graph.Event, bodyText: String?) -> URL? {
        let reported = [event.onlineMeeting?.joinUrl, event.onlineMeetingUrl]
            .lazy
            .compactMap { $0.flatMap(Self.webURL) }
            .first
        return reported ?? bodyText.flatMap { catalog.conferenceMatch(inURL: nil, location: nil, notes: $0)?.url }
    }

    // MARK: - Participants

    private func attendeeDTO(_ attendee: Graph.Attendee) -> AttendeeDTO {
        let address = attendee.emailAddress?.address?.nonBlank
        let (role, type) = Self.roleAndType(attendee.type)
        return AttendeeDTO(
            name: attendee.emailAddress?.name?.nonBlank,
            participantURL: address.flatMap(Self.mailtoURL),
            isCurrentUser: account.isCurrentUser(address: address),
            role: role,
            status: Self.participantStatus(attendee.status?.response),
            type: type
        )
    }

    private func organizerDTO(_ email: Graph.EmailAddress) -> AttendeeDTO {
        let address = email.address?.nonBlank
        return AttendeeDTO(
            name: email.name?.nonBlank,
            participantURL: address.flatMap(Self.mailtoURL),
            isCurrentUser: account.isCurrentUser(address: address),
            role: "chair",
            status: "accepted",
            type: "person"
        )
    }

    /// Graph attendee `type` → EventKit role and participant type strings
    /// (the vocabulary `LiveEventStore` writes). Graph lists rooms as
    /// `resource`.
    static func roleAndType(_ graphType: String?) -> (role: String, type: String) {
        switch graphType?.lowercased() {
        case "required": ("required", "person")
        case "optional": ("optional", "person")
        case "resource": ("nonParticipant", "resource")
        default: ("unknown", "unknown")
        }
    }

    /// Graph `responseStatus.response` → EventKit participant status string.
    static func participantStatus(_ response: String?) -> String {
        switch response?.lowercased() {
        case "accepted", "organizer": "accepted"
        case "tentativelyaccepted": "tentative"
        case "declined": "declined"
        case "notresponded": "pending"
        default: "unknown"
        }
    }

    // MARK: - Helpers

    /// Plain text of the event body, uncapped. Nil when there is no body.
    static func bodyText(_ body: Graph.ItemBody?) -> String? {
        guard let content = body?.content, !content.isEmpty else { return nil }
        if body?.contentType?.lowercased() == "text" {
            return HTMLText.plainText(fromText: content, limit: nil).nonBlank
        }
        return HTMLText.plainText(fromHTML: content, limit: nil).nonBlank
    }

    static func webURL(_ string: String) -> URL? {
        guard let url = URL(string: string.trimmingCharacters(in: .whitespaces)),
              let scheme = url.scheme?.lowercased(), scheme == "https" || scheme == "http"
        else { return nil }
        return url
    }

    static func mailtoURL(_ address: String) -> URL? {
        URL(string: "mailto:\(address)")
    }

    private static func sameAddress(_ lhs: URL?, _ rhs: URL?) -> Bool {
        guard let lhs, let rhs else { return false }
        return lhs.absoluteString.lowercased() == rhs.absoluteString.lowercased()
    }
}

extension String {
    /// Nil when the string is empty or only whitespace.
    var nonBlank: String? {
        trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : self
    }
}
