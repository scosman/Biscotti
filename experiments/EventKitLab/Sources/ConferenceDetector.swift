import Foundation

struct ConferenceInfo: Sendable {
    let url: URL
    let platform: String
}

enum ConferenceDetector {
    struct PlatformPattern: Sendable {
        let platform: String
        let pattern: String
    }

    static let platformPatterns: [PlatformPattern] = [
        PlatformPattern(platform: "zoom", pattern: #"https?://[\w.-]*zoom\.us/j/\d+[^\s]*"#),
        PlatformPattern(platform: "meet", pattern: #"https?://meet\.google\.com/[a-z-]+"#),
        PlatformPattern(platform: "teams", pattern: #"https?://teams\.microsoft\.com/l/meetup-join/[^\s]+"#),
        PlatformPattern(platform: "webex", pattern: #"https?://[\w.-]*webex\.com/[^\s]+"#),
        PlatformPattern(platform: "slack", pattern: #"https?://app\.slack\.com/huddle/[^\s]+"#),
    ]

    static func detect(url: URL?, notes: String?, location: String?) -> ConferenceInfo? {
        if let url, let info = matchURL(url) {
            return info
        }

        let fieldsToScan = [location, notes].compactMap { $0 }
        for field in fieldsToScan {
            if let info = matchInText(field) {
                return info
            }
        }

        return nil
    }

    static func matchURL(_ url: URL) -> ConferenceInfo? {
        let urlString = url.absoluteString
        return matchInText(urlString)
    }

    static func matchInText(_ text: String) -> ConferenceInfo? {
        // NOTE: Production code should cache compiled NSRegularExpression instances
        // rather than recompiling on every call.
        for pp in platformPatterns {
            guard let regex = try? NSRegularExpression(pattern: pp.pattern, options: .caseInsensitive)
            else { continue }
            let range = NSRange(text.startIndex..., in: text)
            if let match = regex.firstMatch(in: text, range: range) {
                let matchRange = Range(match.range, in: text)!
                let matchedString = String(text[matchRange])
                if let matchedURL = URL(string: matchedString) {
                    return ConferenceInfo(url: matchedURL, platform: pp.platform)
                }
            }
        }
        return nil
    }
}
