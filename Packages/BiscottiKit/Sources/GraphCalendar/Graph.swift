import Foundation

/// Microsoft Graph v1.0 wire types: only the fields Biscotti reads.
/// Property names match the JSON, so `Decodable` needs no key mapping except
/// for `@odata.nextLink`. Every field Graph may omit or null is optional.
public enum Graph {
    /// `GET /me` (`$select=id,displayName,mail,userPrincipalName`).
    public struct User: Decodable, Sendable, Equatable {
        public let id: String
        public let displayName: String?
        /// Primary SMTP address. Null for some accounts, so matching falls
        /// back to `userPrincipalName`.
        public let mail: String?
        public let userPrincipalName: String
    }

    /// An entry of `GET /me/calendars`.
    public struct Calendar: Decodable, Sendable, Equatable {
        public let id: String
        public let name: String
        /// `#RRGGBB`, or empty when the calendar uses the default color.
        public let hexColor: String?
        public let isDefaultCalendar: Bool?
        public let canEdit: Bool?
        /// The mailbox that owns the calendar: the user for their own
        /// calendars, someone else for shared or delegated ones.
        public let owner: EmailAddress?
    }

    /// An event as returned by `calendarView` or `GET /me/events/{id}`.
    public struct Event: Decodable, Sendable, Equatable {
        /// Unique per occurrence for recurring meetings.
        public let id: String
        public let iCalUId: String?
        /// Set on occurrences and exceptions; nil for single instances.
        /// Graph's wire name, so it keeps Graph's wording.
        public let seriesMasterId: String? // swiftlint:disable:this inclusive_language
        /// `singleInstance`, `occurrence`, `exception` or `seriesMaster`.
        public let type: String?
        public let subject: String?
        public let start: DateTimeTimeZone
        public let end: DateTimeTimeZone
        /// The occurrence's original start (`Edm.DateTimeOffset`, UTC). Only
        /// meaningful for occurrences and exceptions.
        public let originalStart: String?
        /// The time zone the organizer created the event in. A Windows
        /// zone name ("Pacific Standard Time") or an IANA identifier.
        public let originalStartTimeZone: String?
        public let isAllDay: Bool?
        public let isCancelled: Bool?
        public let isOnlineMeeting: Bool?
        /// `teamsForBusiness`, `skypeForBusiness`, `skypeForConsumer` or
        /// `unknown`.
        public let onlineMeetingProvider: String?
        public let onlineMeeting: OnlineMeetingInfo?
        /// Deprecated by Graph in favor of `onlineMeeting.joinUrl`, but still
        /// populated for some meetings.
        public let onlineMeetingUrl: String?
        public let location: Location?
        public let body: ItemBody?
        /// `free`, `tentative`, `busy`, `oof`, `workingElsewhere` or `unknown`.
        public let showAs: String?
        public let responseStatus: ResponseStatus?
        public let attendees: [Attendee]?
        public let organizer: Recipient?
    }

    /// Graph's `dateTimeTimeZone`: a wall-clock time with no offset, plus
    /// the zone it is in. With `Prefer: outlook.timezone="UTC"` the zone is
    /// `UTC`.
    public struct DateTimeTimeZone: Decodable, Sendable, Equatable {
        /// e.g. `2026-10-23T14:00:00.0000000`.
        public let dateTime: String
        public let timeZone: String?
    }

    public struct OnlineMeetingInfo: Decodable, Sendable, Equatable {
        public let joinUrl: String?
    }

    public struct Location: Decodable, Sendable, Equatable {
        public let displayName: String?
    }

    public struct ItemBody: Decodable, Sendable, Equatable {
        /// `html` or `text`.
        public let contentType: String?
        public let content: String?
    }

    public struct ResponseStatus: Decodable, Sendable, Equatable {
        /// `none`, `organizer`, `tentativelyAccepted`, `accepted`, `declined`
        /// or `notResponded`.
        public let response: String?
    }

    public struct Attendee: Decodable, Sendable, Equatable {
        /// `required`, `optional` or `resource`.
        public let type: String?
        public let status: ResponseStatus?
        public let emailAddress: EmailAddress?
    }

    public struct Recipient: Decodable, Sendable, Equatable {
        public let emailAddress: EmailAddress?
    }

    public struct EmailAddress: Decodable, Sendable, Equatable {
        public let name: String?
        public let address: String?
    }
}

/// A collection response. `nextLink` is absent on the last page.
struct GraphPage<Element: Decodable & Sendable>: Decodable {
    let value: [Element]
    let nextLink: String?

    private enum CodingKeys: String, CodingKey {
        case value
        case nextLink = "@odata.nextLink"
    }
}

/// The `{"error": {"code": …, "message": …}}` body Graph sends with
/// non-2xx responses.
struct GraphErrorResponse: Decodable {
    struct Detail: Decodable {
        let code: String?
        let message: String?
    }

    let error: Detail
}
