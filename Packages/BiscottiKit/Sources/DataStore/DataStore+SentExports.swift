import Foundation

// MARK: - Sent-Export API

public extension DataStore {
    /// Returns the sent-export records for a meeting, or `[]` if the meeting
    /// does not exist.
    func sentExports(meetingID: UUID) throws -> [SentExport] {
        guard let meeting = try meeting(id: meetingID) else { return [] }
        return meeting.sentExports
    }

    /// Records (or replaces) a sent-export for a meeting. If the meeting
    /// already has a record for the same destination, it is replaced; other
    /// destinations are untouched. Silent no-op if the meeting is missing.
    func recordSentExport(_ export: SentExport, meetingID: UUID) throws {
        guard let meeting = try meeting(id: meetingID) else { return }
        var exports = meeting.sentExports
        exports.removeAll { $0.destination == export.destination }
        exports.append(export)
        meeting.sentExports = exports
        try save()
    }
}
