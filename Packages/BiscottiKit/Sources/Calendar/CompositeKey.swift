import Foundation

/// Builds the stable-ish identifier for a calendar event occurrence.
///
/// Format: `"{eventIdentifier}|{calendarItemIdentifier}|{occurrenceStartDateUnixTimestamp}"`
///
/// `calendarItemExternalIdentifier` is stored in the snapshot as a supplementary
/// field for potential cross-device re-linking, but is NOT part of the composite
/// key (it can change after sync, per research findings).
public enum CompositeKey {
    public static func make(
        eventIdentifier: String,
        calendarItemIdentifier: String,
        occurrenceStartDate: Date
    ) -> String {
        let timestamp = Int64(occurrenceStartDate.timeIntervalSince1970)
        return "\(eventIdentifier)|\(calendarItemIdentifier)|\(timestamp)"
    }
}
