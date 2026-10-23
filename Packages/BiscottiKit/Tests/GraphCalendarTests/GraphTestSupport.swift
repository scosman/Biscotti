import Calendar
import Foundation
import Testing
@testable import GraphCalendar

// MARK: - Fixtures

/// Recorded-shape Graph responses under `Fixtures/`. IDs, people and
/// links are made up; field shapes follow Graph v1.0 responses.
enum Fixture {
    static func data(_ name: String) throws -> Data {
        let url = try #require(
            Bundle.module.url(forResource: name, withExtension: "json", subdirectory: "Fixtures"),
            "missing fixture \(name).json"
        )
        return try Data(contentsOf: url)
    }

    static func events(_ name: String) throws -> [Graph.Event] {
        try JSONDecoder().decode(GraphPage<Graph.Event>.self, from: data(name)).value
    }

    static func event(_ name: String, id: String) throws -> Graph.Event {
        try #require(events(name).first { $0.id == id }, "no event \(id) in \(name).json")
    }
}

// MARK: - Fake transport

/// One canned HTTP response.
struct Stub {
    var status: Int
    var headers: [String: String] = [:]
    var body = Data()

    static func fixture(_ name: String, status: Int = 200, headers: [String: String] = [:]) throws -> Stub {
        try Stub(status: status, headers: headers, body: Fixture.data(name))
    }

    static func status(_ status: Int, headers: [String: String] = [:]) -> Stub {
        Stub(status: status, headers: headers)
    }
}

enum FakeTransportError: Error {
    case unexpectedRequest(String)
}

/// Replays canned responses by URL path, in order, repeating the last one,
/// and records every request. `latency` holds each request in flight so
/// the client's concurrency cap is observable.
actor FakeGraphTransport: GraphHTTPTransport {
    private var routes: [String: [Stub]] = [:]
    private(set) var requests: [URLRequest] = []
    private(set) var maxInFlight = 0
    private var inFlight = 0
    private var failure: (any Error)?
    private let latency: Duration?

    init(latency: Duration? = nil) {
        self.latency = latency
    }

    /// `path` is the decoded URL path, e.g. `/v1.0/me/calendars`.
    func stub(_ path: String, _ stubs: Stub...) {
        routes[path, default: []].append(contentsOf: stubs)
    }

    func failAll(with error: any Error) {
        failure = error
    }

    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        requests.append(request)
        inFlight += 1
        maxInFlight = max(maxInFlight, inFlight)
        defer { inFlight -= 1 }
        if let latency {
            try await Task.sleep(for: latency)
        }
        if let failure {
            throw failure
        }
        let url = try #require(request.url)
        let path = url.path(percentEncoded: false)
        guard var queue = routes[path], let stub = queue.first else {
            throw FakeTransportError.unexpectedRequest(path)
        }
        if queue.count > 1 {
            queue.removeFirst()
            routes[path] = queue
        }
        let response = try #require(
            HTTPURLResponse(url: url, statusCode: stub.status, httpVersion: "HTTP/1.1", headerFields: stub.headers)
        )
        return (stub.body, response)
    }
}

// MARK: - Fake tokens and sleeper

/// Issues `token-1`, then a new token on each forced refresh, and records
/// the `forceRefresh` flag of every call.
actor FakeTokens: GraphAccessTokenProviding {
    private(set) var calls: [Bool] = []
    private var issued = 0

    func accessToken(forceRefresh: Bool) async throws -> String {
        calls.append(forceRefresh)
        if forceRefresh || issued == 0 {
            issued += 1
        }
        return "token-\(issued)"
    }
}

/// Records backoff waits instead of sleeping.
actor SleepRecorder {
    private(set) var sleeps: [Duration] = []

    func record(_ duration: Duration) {
        sleeps.append(duration)
    }

    nonisolated var sleeper: GraphClient.Sleeper {
        { duration in await self.record(duration) }
    }
}

// MARK: - Helpers

/// The account and calendars the fixtures are written for.
enum TestAccount {
    static let jane = GraphAccount(userPrincipalName: "jane@synderys.com", mail: "Jane.Doe@synderys.com")
    static let ownCalendar = calendar("cal-own", title: "Calendar")

    static func calendar(_ id: String, title: String) -> CalendarInfo {
        CalendarInfo(id: id, title: title, colorHex: "#808080", sourceTitle: jane.sourceTitle)
    }
}

func makeClient(
    _ transport: FakeGraphTransport,
    tokens: FakeTokens = FakeTokens(),
    sleeper: SleepRecorder = SleepRecorder(),
    retryPolicy: GraphClient.RetryPolicy = GraphClient.RetryPolicy()
) -> GraphClient {
    GraphClient(tokens: tokens, transport: transport, retryPolicy: retryPolicy, sleep: sleeper.sleeper)
}

/// An instant from an ISO 8601 string with an offset, e.g.
/// `2026-10-30T00:00:00-07:00`.
func instant(_ text: String) throws -> Date {
    try #require(ISO8601DateFormatter().date(from: text), "bad test date \(text)")
}

func zone(_ identifier: String) throws -> TimeZone {
    try #require(TimeZone(identifier: identifier), "unknown zone \(identifier)")
}

func query(_ request: URLRequest) throws -> [String: String] {
    let url = try #require(request.url)
    let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
    return Dictionary(items.map { ($0.name, $0.value ?? "") }, uniquingKeysWith: { $1 })
}

func path(_ request: URLRequest) -> String? {
    request.url?.path(percentEncoded: false)
}

/// 2026-10-26T00:00:00Z to 2026-11-02T00:00:00Z, the fixtures' week.
let testWeek = DateInterval(
    start: Date(timeIntervalSince1970: 1_792_972_800),
    end: Date(timeIntervalSince1970: 1_793_577_600)
)
