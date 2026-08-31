import Foundation

public extension AppLink {
    /// Parses a `biscotti://` URL. Returns nil for anything unrecognized.
    ///
    /// Rejections are shape-level only: wrong scheme, unknown route,
    /// malformed UUID, unparseable `time`, or a missing required
    /// parameter. Unknown query parameters are ignored, keeping links
    /// forward-compatible.
    init?(url: URL) {
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              components.scheme?.lowercased() == "biscotti",
              let host = components.host?.lowercased(),
              let link = Self.route(host: host, components: components)
        else { return nil }
        self = link
    }
}

private extension AppLink {
    static func route(host: String, components: URLComponents) -> AppLink? {
        switch host {
        case "home": .home
        case "meetings": .meetings
        case "settings": .settings
        case "meeting": meeting(components)
        case "search": search(components)
        case "upcoming": upcoming(components)
        case "record": record(components)
        default: nil
        }
    }

    /// First query item with the given name, so unknown parameters are
    /// structurally ignored.
    static func item(named name: String, in components: URLComponents) -> URLQueryItem? {
        components.queryItems?.first(where: { $0.name == name })
    }

    static func meeting(_ components: URLComponents) -> AppLink? {
        guard let id = meetingID(inPath: components.path),
              let target = meetingTarget(
                  time: item(named: "time", in: components)?.value,
                  tab: item(named: "tab", in: components)?.value
              )
        else { return nil }
        return .meeting(id: id, target: target)
    }

    static func search(_ components: URLComponents) -> AppLink? {
        // The query parameter must be present, but its value may be empty —
        // `biscotti://search?query=` is the "open search" affordance, while
        // a wholly absent parameter is a no-op.
        guard let queryItem = item(named: "query", in: components) else { return nil }
        return .search(query: queryItem.value ?? "")
    }

    static func upcoming(_ components: URLComponents) -> AppLink? {
        guard let key = item(named: "key", in: components)?.value, !key.isEmpty else { return nil }
        return .upcoming(key: key)
    }

    static func record(_ components: URLComponents) -> AppLink? {
        .record(title: item(named: "title", in: components)?.value.flatMap(trimmedTitle))
    }

    /// The path is `/{uuid}`; a value that is not exactly one UUID string
    /// (including an empty or multi-segment path) fails to parse.
    static func meetingID(inPath path: String) -> UUID? {
        let raw = path.hasPrefix("/") ? String(path.dropFirst()) : path
        return UUID(uuidString: raw)
    }

    /// Resolves `?time`/`?tab` per the documented precedence: a present
    /// `time` must parse (an unparseable number rejects the whole URL),
    /// a parseable `time` beats `tab`, an unrecognized `tab` value falls
    /// back to `.summary`.
    static func meetingTarget(time: String?, tab: String?) -> MeetingTarget? {
        if let time {
            guard let seconds = Double(time) else { return nil }
            return .transcriptTime(seconds)
        }
        if let tab, let meetingTab = MeetingTab(rawValue: tab.lowercased()) {
            return .tab(meetingTab)
        }
        return .tab(.summary)
    }

    /// A `record` title that is empty or whitespace-only is treated as
    /// absent, so the recording keeps its default (AI-titling-eligible)
    /// title.
    static func trimmedTitle(_ title: String) -> String? {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
