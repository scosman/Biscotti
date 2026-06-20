import Foundation

/// Helpers for building and parsing custom speaker-link URLs used
/// in transcript speaker spans. The URL scheme `biscotti://speaker?id=<speakerID>`
/// is intercepted by the view's `OpenURLAction` to open the speaker
/// mapping sheet focused on that speaker.
public enum SpeakerLink {
    /// Builds a speaker URL for the given diarization speaker ID.
    public static func url(speakerID: Int) -> URL {
        var components = URLComponents()
        components.scheme = "biscotti"
        components.host = "speaker"
        components.queryItems = [
            URLQueryItem(name: "id", value: "\(speakerID)")
        ]
        guard let url = components.url else {
            preconditionFailure(
                "Failed to build speaker URL for id=\(speakerID)"
            )
        }
        return url
    }

    /// Parses a speaker URL and returns the speaker ID, or nil if the URL
    /// is not a valid speaker link.
    public static func speakerID(from url: URL) -> Int? {
        guard url.scheme == "biscotti",
              url.host == "speaker"
        else { return nil }

        guard let components = URLComponents(
            url: url, resolvingAgainstBaseURL: false
        ),
            let idValue = components.queryItems?
            .first(where: { $0.name == "id" })?.value,
            let speakerID = Int(idValue)
        else { return nil }

        return speakerID
    }
}
