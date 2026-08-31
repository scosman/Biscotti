import Foundation

public extension AppLink {
    /// The canonical URL for this link. Non-failable: every case maps to a
    /// well-formed URL, built through `URLComponents` so all values are
    /// percent-encoded.
    var url: URL {
        var components = URLComponents()
        components.scheme = "biscotti"
        switch self {
        case .home:
            components.host = "home"
        case .meetings:
            components.host = "meetings"
        case .settings:
            components.host = "settings"
        case let .meeting(id, target):
            components.host = "meeting"
            components.path = "/\(id.uuidString)"
            switch target {
            case let .tab(tab):
                if tab != .summary {
                    components.queryItems = [URLQueryItem(name: "tab", value: tab.rawValue)]
                }
            case let .transcriptTime(seconds):
                components.queryItems = [URLQueryItem(name: "time", value: Self.timeValue(seconds))]
            }
        case let .search(query):
            components.host = "search"
            components.queryItems = [URLQueryItem(name: "query", value: query)]
        case let .upcoming(key):
            components.host = "upcoming"
            components.queryItems = [URLQueryItem(name: "key", value: key)]
        case let .record(title):
            components.host = "record"
            if let title {
                components.queryItems = [URLQueryItem(name: "title", value: title)]
            }
        }
        guard let url = components.url else {
            fatalError("AppLink \(self) does not encode to a URL")
        }
        return url
    }
}

private extension AppLink {
    /// Whole-number times render without a fractional part (`42`, not
    /// `42.0`), matching the documented URL vocabulary; every other value
    /// uses `Double`'s shortest round-tripping description.
    static func timeValue(_ seconds: TimeInterval) -> String {
        seconds.isFinite && seconds == seconds.rounded()
            ? String(format: "%.0f", seconds)
            : "\(seconds)"
    }
}
