import Foundation

/// Read-only Microsoft Graph client for the calendar endpoints Biscotti
/// uses. Handles the token (one forced refresh on 401), throttling (honors
/// `Retry-After` on 429/503, exponential backoff without it), paging via
/// `@odata.nextLink`, and Graph's limit of 4 concurrent requests per
/// mailbox.
///
/// Requests ask for UTC times (`Prefer: outlook.timezone="UTC"`) so the
/// mapper never has to resolve a Windows zone name for `start`/`end`.
public actor GraphClient {
    public struct RetryPolicy: Sendable {
        /// Retries after the first attempt for a 429/503.
        public var maxRetries: Int
        /// Backoff when `Retry-After` is missing: `baseDelay * 2^attempt`.
        public var baseDelay: TimeInterval
        /// Upper bound on any single wait, including a server hint.
        public var maxDelay: TimeInterval

        public init(maxRetries: Int = 3, baseDelay: TimeInterval = 1, maxDelay: TimeInterval = 60) {
            self.maxRetries = maxRetries
            self.baseDelay = baseDelay
            self.maxDelay = maxDelay
        }
    }

    public typealias Sleeper = @Sendable (Duration) async throws -> Void

    public static let defaultBaseURL = URL(string: "https://graph.microsoft.com/v1.0/")!

    /// Graph allows 4 concurrent requests per app per mailbox.
    static let maxConcurrentRequests = 4
    /// Page size requested from collection endpoints.
    static let pageSize = 100
    /// Stops paging after this many pages (10,000 items at `pageSize`). A
    /// guard against a server that keeps returning `nextLink`, not a limit
    /// real calendars reach in the 7-day window.
    static let maxPages = 100

    /// Event fields the mapper reads. Graph returns only these.
    static let eventSelect = [
        "id", "iCalUId", "seriesMasterId", "type", "subject", "start", "end",
        "originalStart", "originalStartTimeZone", "isAllDay", "isCancelled",
        "isOnlineMeeting", "onlineMeetingProvider", "onlineMeeting",
        "onlineMeetingUrl", "location", "body", "showAs", "responseStatus",
        "attendees", "organizer"
    ].joined(separator: ",")
    static let calendarSelect = "id,name,hexColor,isDefaultCalendar,canEdit,owner"
    static let userSelect = "id,displayName,mail,userPrincipalName"
    static let preferUTC = "outlook.timezone=\"UTC\""

    private let tokens: any GraphAccessTokenProviding
    private let transport: any GraphHTTPTransport
    private let baseURL: URL
    private let retryPolicy: RetryPolicy
    private let sleep: Sleeper

    private var inFlight = 0
    private var slotWaiters: [CheckedContinuation<Void, Never>] = []

    public init(
        tokens: any GraphAccessTokenProviding,
        transport: any GraphHTTPTransport = URLSessionGraphTransport(),
        baseURL: URL = GraphClient.defaultBaseURL,
        retryPolicy: RetryPolicy = RetryPolicy(),
        sleep: @escaping Sleeper = { try await Task.sleep(for: $0) }
    ) {
        self.tokens = tokens
        self.transport = transport
        self.baseURL = baseURL
        self.retryPolicy = retryPolicy
        self.sleep = sleep
    }

    // MARK: - Endpoints

    /// `GET /me`: the signed-in user, for `isCurrentUser` matching and the
    /// account label.
    public func me() async throws -> Graph.User {
        let url = try makeURL(["me"], query: [URLQueryItem(name: "$select", value: Self.userSelect)])
        return try await decode(Graph.User.self, from: get(url))
    }

    /// `GET /me/calendars`, all pages. Includes calendars shared with the
    /// user that they have added to Outlook.
    public func calendars() async throws -> [Graph.Calendar] {
        let url = try makeURL(["me", "calendars"], query: [
            URLQueryItem(name: "$select", value: Self.calendarSelect),
            URLQueryItem(name: "$top", value: String(Self.pageSize))
        ])
        return try await collect(Graph.Calendar.self, from: url, preferUTC: false)
    }

    /// `GET /me/calendars/{id}/calendarView`, all pages. Recurring meetings
    /// come back expanded into occurrences, which is why this is used
    /// instead of `/events`.
    public func calendarView(calendarID: String, in interval: DateInterval) async throws -> [Graph.Event] {
        let url = try makeURL(["me", "calendars", calendarID, "calendarView"], query: [
            URLQueryItem(name: "startDateTime", value: Self.isoString(interval.start)),
            URLQueryItem(name: "endDateTime", value: Self.isoString(interval.end)),
            URLQueryItem(name: "$select", value: Self.eventSelect),
            URLQueryItem(name: "$top", value: String(Self.pageSize))
        ])
        return try await collect(Graph.Event.self, from: url, preferUTC: true)
    }

    /// `GET /me/calendars/{calendarID}/events/{id}`, or `/me/events/{id}`
    /// without a calendar. The calendar-scoped path also reaches events on
    /// calendars shared with the user, which `/me/events` does not. Returns
    /// nil when the event no longer exists (404), which is how
    /// `refreshEvent` learns it was deleted.
    public func event(id: String, calendarID: String? = nil) async throws -> Graph.Event? {
        let segments = calendarID.map { ["me", "calendars", $0, "events", id] } ?? ["me", "events", id]
        let url = try makeURL(segments, query: [
            URLQueryItem(name: "$select", value: Self.eventSelect)
        ])
        do {
            return try await decode(Graph.Event.self, from: get(url, preferUTC: true))
        } catch let GraphError.http(status, _, _) where status == 404 {
            return nil
        }
    }

    // MARK: - Request pipeline

    private func collect<Element: Decodable & Sendable>(
        _: Element.Type,
        from firstURL: URL,
        preferUTC: Bool
    ) async throws -> [Element] {
        var items: [Element] = []
        var next: URL? = firstURL
        var pages = 0
        while let url = next {
            let page = try await decode(GraphPage<Element>.self, from: get(url, preferUTC: preferUTC))
            items.append(contentsOf: page.value)
            pages += 1
            guard let link = page.nextLink else { break }
            guard pages < Self.maxPages else {
                graphCalendarLog.error("Stopped paging after \(pages) pages; results are incomplete")
                break
            }
            next = try trustedNextLink(link)
        }
        return items
    }

    /// GET with auth, one forced token refresh on 401, and throttling
    /// retries. Returns the body of a 2xx response.
    private func get(_ url: URL, preferUTC: Bool = false) async throws -> Data {
        var forceRefresh = false
        var refreshed = false
        var throttleRetries = 0
        while true {
            try Task.checkCancellation()
            let token = try await tokens.accessToken(forceRefresh: forceRefresh)
            forceRefresh = false

            var request = URLRequest(url: url)
            request.httpMethod = "GET"
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            request.setValue("application/json", forHTTPHeaderField: "Accept")
            if preferUTC {
                request.setValue(Self.preferUTC, forHTTPHeaderField: "Prefer")
            }

            let (data, response) = try await send(request)
            let status = response.statusCode
            switch status {
            case 200 ..< 300:
                return data
            case 401 where !refreshed:
                refreshed = true
                forceRefresh = true
            case 401:
                throw GraphError.unauthorized
            case 429, 503:
                let hint = Self.retryAfter(response)
                guard throttleRetries < retryPolicy.maxRetries else {
                    throw GraphError.throttled(retryAfter: hint)
                }
                let delay = min(hint ?? retryPolicy.baseDelay * pow(2, Double(throttleRetries)), retryPolicy.maxDelay)
                throttleRetries += 1
                graphCalendarLog.info("Graph returned \(status); retry \(throttleRetries) in \(delay)s")
                try await sleep(.milliseconds(Int(delay * 1000)))
            default:
                let detail = try? JSONDecoder().decode(GraphErrorResponse.self, from: data).error
                if status == 403 {
                    throw GraphError.forbidden(code: detail?.code, message: detail?.message)
                }
                throw GraphError.http(status: status, code: detail?.code, message: detail?.message)
            }
        }
    }

    /// One transport call inside a concurrency slot. The slot is released
    /// before any backoff sleep, so a throttled request does not hold it.
    private func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        await acquireSlot()
        defer { releaseSlot() }
        do {
            return try await transport.send(request)
        } catch let error as GraphError {
            throw error
        } catch {
            if Task.isCancelled { throw CancellationError() }
            throw GraphError.transport(error.localizedDescription)
        }
    }

    private func acquireSlot() async {
        if inFlight < Self.maxConcurrentRequests {
            inFlight += 1
            return
        }
        // `releaseSlot` hands its slot straight to the first waiter, so
        // `inFlight` is unchanged here.
        await withCheckedContinuation { slotWaiters.append($0) }
    }

    private func releaseSlot() {
        if slotWaiters.isEmpty {
            inFlight -= 1
        } else {
            slotWaiters.removeFirst().resume()
        }
    }

    // MARK: - Helpers

    private func decode<T: Decodable>(_: T.Type, from data: Data) throws -> T {
        do {
            return try JSONDecoder().decode(T.self, from: data)
        } catch {
            throw GraphError.decoding(String(describing: error))
        }
    }

    /// Builds `<baseURL>/<segments>?<query>`, percent-encoding each segment
    /// on its own so an ID containing `/` or `+` stays one segment.
    private func makeURL(_ segments: [String], query: [URLQueryItem]) throws -> URL {
        guard var components = URLComponents(url: baseURL, resolvingAgainstBaseURL: false) else {
            throw GraphError.invalidRequest("Bad base URL: \(baseURL)")
        }
        var segmentAllowed = CharacterSet.urlPathAllowed
        segmentAllowed.remove(charactersIn: "/+")
        let encoded = segments.map { $0.addingPercentEncoding(withAllowedCharacters: segmentAllowed) ?? $0 }
        var basePath = components.percentEncodedPath
        while basePath.hasSuffix("/") {
            basePath.removeLast()
        }
        components.percentEncodedPath = basePath + "/" + encoded.joined(separator: "/")
        components.queryItems = query.isEmpty ? nil : query
        guard let url = components.url else {
            throw GraphError.invalidRequest("Could not build a URL for \(segments.joined(separator: "/"))")
        }
        return url
    }

    /// Only follows a `nextLink` on the same scheme and host as `baseURL`.
    private func trustedNextLink(_ link: String) throws -> URL {
        guard let url = URL(string: link),
              url.scheme?.lowercased() == baseURL.scheme?.lowercased(),
              url.host?.lowercased() == baseURL.host?.lowercased()
        else {
            throw GraphError.untrustedNextLink(link)
        }
        return url
    }

    /// `Retry-After` in seconds. Graph sends delta-seconds; an HTTP-date or
    /// garbage yields nil, which falls back to exponential backoff.
    static func retryAfter(_ response: HTTPURLResponse) -> TimeInterval? {
        guard let value = response.value(forHTTPHeaderField: "Retry-After"),
              let seconds = TimeInterval(value.trimmingCharacters(in: .whitespaces)),
              seconds >= 0
        else { return nil }
        return seconds
    }

    static func isoString(_ date: Date) -> String {
        date.formatted(.iso8601)
    }
}
