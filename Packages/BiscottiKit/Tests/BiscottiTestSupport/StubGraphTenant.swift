import Foundation
import GraphAuth
import GraphCalendar

/// A Microsoft 365 tenant in memory for AppCore and UI tests. Answers the
/// token endpoint with an access token, and Graph's `/me`, `/me/calendars`
/// and `calendarView` (filtered to the requested window) from `calendars`
/// and `events`. Any other request fails. Give the same instance to
/// `Microsoft365Fixture(transport:)` and the calendar sync.
public actor StubGraphTenant: GraphHTTPTransport {
    public struct Person: Sendable {
        public var name: String
        public var address: String

        public init(_ name: String, _ address: String) {
            self.name = name
            self.address = address
        }
    }

    public struct Event: Sendable {
        public var id: String
        public var calendarID: String
        public var subject: String
        /// Whole seconds: Graph's `dateTime` has no time zone and the stub
        /// writes it in UTC without fractions.
        public var start: Date
        public var end: Date
        public var joinURL: String?
        public var organizer: Person?
        public var attendees: [Person]

        public init(
            id: String,
            calendarID: String = StubGraphTenant.defaultCalendarID,
            subject: String,
            start: Date,
            end: Date,
            joinURL: String? = nil,
            organizer: Person? = nil,
            attendees: [Person] = []
        ) {
            self.id = id
            self.calendarID = calendarID
            self.subject = subject
            self.start = start
            self.end = end
            self.joinURL = joinURL
            self.organizer = organizer
            self.attendees = attendees
        }
    }

    public static let defaultCalendarID = "cal-work"

    private let account: Microsoft365Account
    private var calendars: [(id: String, name: String)] = [(defaultCalendarID, "Calendar")]
    private var events: [Event]
    private var isOffline = false
    public private(set) var requests: [URLRequest] = []

    public init(account: Microsoft365Account = Microsoft365Fixture.account, events: [Event] = []) {
        self.account = account
        self.events = events
    }

    public func setEvents(_ events: [Event]) {
        self.events = events
    }

    public func setCalendars(_ calendars: [(id: String, name: String)]) {
        self.calendars = calendars
    }

    /// Fails every request as offline until set back.
    public func setOffline(_ offline: Bool) {
        isOffline = offline
    }

    /// The windows of the `calendarView` requests so far, in order.
    public var calendarViewWindows: [DateInterval] {
        requests.compactMap { $0.url.flatMap(Self.window) }
    }

    public func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        requests.append(request)
        guard let url = request.url else { throw URLError(.badURL) }
        if isOffline { throw URLError(.notConnectedToInternet) }
        let body = try reply(to: url)
        let data = try JSONSerialization.data(withJSONObject: body)
        guard let response = HTTPURLResponse(
            url: url,
            statusCode: 200,
            httpVersion: "HTTP/1.1",
            headerFields: ["Content-Type": "application/json"]
        ) else { throw URLError(.badServerResponse) }
        return (data, response)
    }

    private func reply(to url: URL) throws -> [String: Any] {
        let path = url.path(percentEncoded: false)
        if path.hasSuffix("/oauth2/v2.0/token") {
            return ["token_type": "Bearer", "access_token": "access-1", "expires_in": 3600]
        }
        if path == "/v1.0/me" {
            return [
                "id": account.objectID,
                "displayName": account.displayName ?? account.username,
                "mail": account.username,
                "userPrincipalName": account.username
            ]
        }
        if path == "/v1.0/me/calendars" {
            return ["value": calendars.enumerated().map { index, calendar in
                ["id": calendar.id, "name": calendar.name, "hexColor": "", "isDefaultCalendar": index == 0, "canEdit": true]
            }]
        }
        let parts = path.split(separator: "/")
        if parts.count == 5, parts[1] == "me", parts[2] == "calendars", parts[4] == "calendarView",
           let window = Self.window(url)
        {
            let calendarID = String(parts[3])
            return ["value": events
                .filter { $0.calendarID == calendarID && $0.start < window.end && $0.end > window.start }
                .map(Self.json)]
        }
        throw URLError(.unsupportedURL)
    }

    private static func window(_ url: URL) -> DateInterval? {
        let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        let formatter = ISO8601DateFormatter()
        guard let start = items.first(where: { $0.name == "startDateTime" })?.value.flatMap(formatter.date),
              let end = items.first(where: { $0.name == "endDateTime" })?.value.flatMap(formatter.date),
              start <= end
        else { return nil }
        return DateInterval(start: start, end: end)
    }

    private static func json(_ event: Event) -> [String: Any] {
        var json: [String: Any] = [
            "id": event.id,
            "type": "singleInstance",
            "subject": event.subject,
            "start": ["dateTime": graphDateTime(event.start), "timeZone": "UTC"],
            "end": ["dateTime": graphDateTime(event.end), "timeZone": "UTC"],
            "originalStartTimeZone": "UTC",
            "isAllDay": false,
            "isCancelled": false,
            "isOnlineMeeting": event.joinURL != nil,
            "showAs": "busy",
            "attendees": event.attendees.map { person in
                ["type": "required", "status": ["response": "accepted"], "emailAddress": address(person)]
            }
        ]
        json["onlineMeeting"] = event.joinURL.map { ["joinUrl": $0] }
        json["organizer"] = event.organizer.map { ["emailAddress": address($0)] }
        return json
    }

    private static func address(_ person: Person) -> [String: String] {
        ["name": person.name, "address": person.address]
    }

    private static func graphDateTime(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = "yyyy-MM-dd'T'HH:mm:ss'.0000000'"
        return formatter.string(from: date)
    }
}
