import DataStore
import Foundation

/// Whether to send immediately or show the "already sent" alert
/// (functional spec §2).
public enum SendDecision: Equatable, Sendable {
    /// No record exists for this destination -- send now.
    case send
    /// A record exists. `changed` is true when the current content hash
    /// differs from the recorded one.
    case alreadySent(sentAt: Date, changed: Bool)

    /// Decide what to do given the meeting's sent-export records, the
    /// destination, and the current content hash.
    public static func decide(
        _ records: [SentExport],
        for destination: ExportDestination,
        currentHash: String
    ) -> SendDecision {
        guard let record = records.first(where: { $0.destination == destination }) else {
            return .send
        }
        let changed = record.contentHash != currentHash
        return .alreadySent(sentAt: record.sentAt, changed: changed)
    }
}
