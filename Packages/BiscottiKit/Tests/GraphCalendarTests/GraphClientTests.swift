import Foundation
import Testing
@testable import GraphCalendar

/// `GraphClient` against a fake transport: request shape, paging,
/// throttling, token refresh and error mapping.
@Suite("GraphClient")
struct GraphClientTests {
    private static let calendarViewPath = "/v1.0/me/calendars/cal-own/calendarView"

    // MARK: - Request shape

    @Test("GET /me sends the bearer token and $select")
    func meRequestShape() async throws {
        let transport = FakeGraphTransport()
        try await transport.stub("/v1.0/me", .fixture("me"))
        let user = try await makeClient(transport).me()

        #expect(user.userPrincipalName == "jane@synderys.com")
        #expect(user.mail == "Jane.Doe@synderys.com")
        let request = try #require(await transport.requests.first)
        #expect(request.httpMethod == "GET")
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer token-1")
        #expect(try query(request)["$select"] == GraphClient.userSelect)
        // Only calendarView and event reads ask for UTC times.
        #expect(request.value(forHTTPHeaderField: "Prefer") == nil)
    }

    @Test("calendarView sends the window, page size and Prefer UTC")
    func calendarViewRequestShape() async throws {
        let transport = FakeGraphTransport()
        try await transport.stub(Self.calendarViewPath, .fixture("calendarView_empty"))
        let events = try await makeClient(transport).calendarView(calendarID: "cal-own", in: testWeek)

        #expect(events.isEmpty)
        let request = try #require(await transport.requests.first)
        let items = try query(request)
        #expect(items["startDateTime"] == "2026-10-26T00:00:00Z")
        #expect(items["endDateTime"] == "2026-11-02T00:00:00Z")
        #expect(items["$top"] == "100")
        #expect(items["$select"] == GraphClient.eventSelect)
        #expect(request.value(forHTTPHeaderField: "Prefer") == #"outlook.timezone="UTC""#)
    }

    @Test("IDs are percent-encoded as single path segments")
    func idsArePercentEncoded() async throws {
        let transport = FakeGraphTransport()
        try await transport.stub("/v1.0/me/calendars/AAMk/ab+c=/calendarView", .fixture("calendarView_empty"))
        _ = try await makeClient(transport).calendarView(calendarID: "AAMk/ab+c=", in: testWeek)

        let url = try #require(await transport.requests.first?.url)
        #expect(url.path(percentEncoded: true) == "/v1.0/me/calendars/AAMk%2Fab%2Bc=/calendarView")
    }

    @Test("event reads use the calendar-scoped path when given a calendar")
    func eventPaths() async throws {
        let transport = FakeGraphTransport()
        try await transport.stub("/v1.0/me/calendars/cal-shared/events/evt-teams", .fixture("event_teams"))
        try await transport.stub("/v1.0/me/events/evt-teams", .fixture("event_teams"))
        let client = makeClient(transport)

        let scoped = try await client.event(id: "evt-teams", calendarID: "cal-shared")
        let unscoped = try await client.event(id: "evt-teams")

        #expect(scoped?.id == "evt-teams")
        #expect(unscoped?.subject == "Q4 pipeline review")
        let requests = await transport.requests
        #expect(requests.map(path) == [
            "/v1.0/me/calendars/cal-shared/events/evt-teams",
            "/v1.0/me/events/evt-teams"
        ])
        #expect(requests.allSatisfy { $0.value(forHTTPHeaderField: "Prefer") == GraphClient.preferUTC })
    }

    @Test("a deleted event (404) reads as nil")
    func deletedEventIsNil() async throws {
        let transport = FakeGraphTransport()
        try await transport.stub(
            "/v1.0/me/calendars/cal-own/events/evt-gone", .fixture("error_404", status: 404)
        )
        let event = try await makeClient(transport).event(id: "evt-gone", calendarID: "cal-own")
        #expect(event == nil)
    }

    // MARK: - Paging

    @Test("collections follow @odata.nextLink until the last page")
    func pagingFollowsNextLink() async throws {
        let transport = FakeGraphTransport()
        try await transport.stub(
            Self.calendarViewPath, .fixture("calendarView_page1"), .fixture("calendarView_page2")
        )
        let events = try await makeClient(transport).calendarView(calendarID: "cal-own", in: testWeek)

        #expect(events.map(\.id) == ["evt-p1", "evt-p2", "evt-p3"])
        let requests = await transport.requests
        #expect(requests.count == 2)
        #expect(requests.last?.url?.absoluteString == "https://graph.microsoft.com/v1.0/me/calendars/cal-own/calendarView?startDateTime=2026-10-26T00:00:00Z&endDateTime=2026-11-02T00:00:00Z&$select=id,subject&$top=2&$skip=2")
        #expect(requests.last?.value(forHTTPHeaderField: "Authorization") == "Bearer token-1")
    }

    @Test("a nextLink to another host is refused, not followed")
    func untrustedNextLinkIsRefused() async throws {
        let transport = FakeGraphTransport()
        try await transport.stub(Self.calendarViewPath, .fixture("calendarView_untrusted_next"))

        await #expect(
            throws: GraphError.untrustedNextLink("https://graph.evil.example/v1.0/me/calendars/cal-own/calendarView?$skip=1")
        ) {
            try await makeClient(transport).calendarView(calendarID: "cal-own", in: testWeek)
        }
        #expect(await transport.requests.count == 1)
    }

    // MARK: - Throttling

    @Test("429 waits the Retry-After seconds, then retries")
    func retryAfterIsHonored() async throws {
        let transport = FakeGraphTransport()
        try await transport.stub(
            "/v1.0/me",
            .fixture("error_429", status: 429, headers: ["Retry-After": "7"]),
            .fixture("me")
        )
        let sleeper = SleepRecorder()
        let user = try await makeClient(transport, sleeper: sleeper).me()

        #expect(user.id == "8f1c2a4e-5b7d-4b6e-9c3d-2a7e5d0f9b01")
        #expect(await sleeper.sleeps == [.seconds(7)])
        #expect(await transport.requests.count == 2)
    }

    @Test("503 without Retry-After backs off exponentially")
    func backoffWithoutRetryAfter() async throws {
        let transport = FakeGraphTransport()
        try await transport.stub("/v1.0/me", .status(503), .status(503), .fixture("me"))
        let sleeper = SleepRecorder()
        _ = try await makeClient(transport, sleeper: sleeper).me()

        #expect(await sleeper.sleeps == [.seconds(1), .seconds(2)])
    }

    @Test("a server hint is capped at maxDelay")
    func retryAfterIsCapped() async throws {
        let transport = FakeGraphTransport()
        try await transport.stub("/v1.0/me", .status(429, headers: ["Retry-After": "600"]), .fixture("me"))
        let sleeper = SleepRecorder()
        _ = try await makeClient(transport, sleeper: sleeper).me()

        #expect(await sleeper.sleeps == [.seconds(60)])
    }

    @Test("throttling on every attempt throws after maxRetries")
    func throttledAfterMaxRetries() async throws {
        let transport = FakeGraphTransport()
        try await transport.stub("/v1.0/me", .fixture("error_429", status: 429, headers: ["Retry-After": "2"]))
        let sleeper = SleepRecorder()

        await #expect(throws: GraphError.throttled(retryAfter: 2)) {
            try await makeClient(transport, sleeper: sleeper).me()
        }
        #expect(await transport.requests.count == 4)
        #expect(await sleeper.sleeps == [.seconds(2), .seconds(2), .seconds(2)])
    }

    @Test("Retry-After parsing", arguments: [
        ("120", 120.0), (" 5 ", 5.0), ("0", 0.0),
        ("Wed, 21 Oct 2026 07:28:00 GMT", nil), ("-3", nil), ("soon", nil)
    ] as [(String, TimeInterval?)])
    func retryAfterParsing(header: String, expected: TimeInterval?) throws {
        let url = try #require(URL(string: "https://graph.microsoft.com/v1.0/me"))
        let response = try #require(
            HTTPURLResponse(url: url, statusCode: 429, httpVersion: nil, headerFields: ["Retry-After": header])
        )
        #expect(GraphClient.retryAfter(response) == expected)
    }

    // MARK: - Auth

    @Test("401 forces one token refresh and retries")
    func unauthorizedRefreshesOnce() async throws {
        let transport = FakeGraphTransport()
        try await transport.stub("/v1.0/me", .fixture("error_401", status: 401), .fixture("me"))
        let tokens = FakeTokens()
        _ = try await makeClient(transport, tokens: tokens).me()

        #expect(await tokens.calls == [false, true])
        let headers = await transport.requests.map { $0.value(forHTTPHeaderField: "Authorization") }
        #expect(headers == ["Bearer token-1", "Bearer token-2"])
    }

    @Test("401 after the refresh throws unauthorized")
    func unauthorizedTwiceThrows() async throws {
        let transport = FakeGraphTransport()
        try await transport.stub("/v1.0/me", .fixture("error_401", status: 401))

        await #expect(throws: GraphError.unauthorized) {
            try await makeClient(transport).me()
        }
        #expect(await transport.requests.count == 2)
    }

    // MARK: - Errors

    @Test("403 carries Graph's error code and message")
    func forbiddenParsesErrorBody() async throws {
        let transport = FakeGraphTransport()
        try await transport.stub("/v1.0/me/calendars", .fixture("error_403", status: 403))

        await #expect(throws: GraphError.forbidden(
            code: "ErrorAccessDenied", message: "Access is denied. Check credentials and try again."
        )) {
            try await makeClient(transport).calendars()
        }
    }

    @Test("other statuses map to http, with or without an error body")
    func otherStatusesMapToHTTP() async throws {
        let transport = FakeGraphTransport()
        await transport.stub("/v1.0/me", .status(500))

        await #expect(throws: GraphError.http(status: 500, code: nil, message: nil)) {
            try await makeClient(transport).me()
        }
    }

    @Test("an unparseable 2xx body is a decoding error")
    func badBodyIsDecodingError() async throws {
        let transport = FakeGraphTransport()
        await transport.stub("/v1.0/me", Stub(status: 200, body: Data("<html>".utf8)))

        let error = await #expect(throws: GraphError.self) {
            try await makeClient(transport).me()
        }
        guard case .decoding? = error else {
            Issue.record("expected .decoding, got \(String(describing: error))")
            return
        }
    }

    @Test("network failures are wrapped as transport errors")
    func networkFailureIsTransportError() async throws {
        let transport = FakeGraphTransport()
        await transport.failAll(with: URLError(.notConnectedToInternet))

        let error = await #expect(throws: GraphError.self) {
            try await makeClient(transport).me()
        }
        guard case .transport? = error else {
            Issue.record("expected .transport, got \(String(describing: error))")
            return
        }
    }

    // MARK: - Concurrency

    @Test("no more than 4 requests are in flight at once")
    func concurrencyIsCapped() async throws {
        let transport = FakeGraphTransport(latency: .milliseconds(50))
        let calendarIDs = (1 ... 10).map { "cal-\($0)" }
        for id in calendarIDs {
            try await transport.stub("/v1.0/me/calendars/\(id)/calendarView", .fixture("calendarView_empty"))
        }
        let client = makeClient(transport)

        try await withThrowingTaskGroup(of: Void.self) { group in
            for id in calendarIDs {
                group.addTask { _ = try await client.calendarView(calendarID: id, in: testWeek) }
            }
            try await group.waitForAll()
        }

        #expect(await transport.requests.count == 10)
        let peak = await transport.maxInFlight
        #expect(peak <= GraphClient.maxConcurrentRequests)
        #expect(peak >= 2, "requests should overlap up to the cap")
    }
}
