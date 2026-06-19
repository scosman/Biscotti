import Foundation

/// Helpers for building and parsing custom seek-link URLs used
/// in transcript timestamps. The URL scheme `biscotti://seek?t=<seconds>`
/// is intercepted by the view's `OpenURLAction` to drive playback seeking.
public enum SeekLink {
    /// Builds a seek URL for the given time offset.
    public static func url(seconds: TimeInterval) -> URL {
        var components = URLComponents()
        components.scheme = "biscotti"
        components.host = "seek"
        components.queryItems = [URLQueryItem(name: "t", value: "\(seconds)")]
        // The components are always well-formed; a nil URL here is a
        // programming error, not a runtime condition.
        guard let url = components.url else {
            preconditionFailure("Failed to build seek URL for t=\(seconds)")
        }
        return url
    }

    /// Parses a seek URL and returns the time offset, or nil if the URL
    /// is not a valid seek link.
    public static func seconds(from url: URL) -> TimeInterval? {
        guard url.scheme == "biscotti",
              url.host == "seek"
        else { return nil }

        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let tValue = components.queryItems?.first(where: { $0.name == "t" })?.value,
              let seconds = Double(tValue)
        else { return nil }

        return seconds
    }
}
