import Foundation

/// Extracts an email address from a participant URL.
///
/// EKParticipant.emailAddress is not public in Swift. The documented approach
/// is to check the URL scheme -- `mailto:` URLs contain the email in the
/// resource specifier. Non-mailto URLs (e.g. Exchange X500 addresses) return nil.
enum EmailParser {
    static func email(from participantURL: URL?) -> String? {
        guard let url = participantURL,
              url.scheme == "mailto"
        else { return nil }
        guard let specifier = (url as NSURL).resourceSpecifier,
              !specifier.isEmpty
        else { return nil }
        return specifier
    }
}
