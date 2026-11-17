import CryptoKit
import Foundation
import STTLabCore

/// Errors from the confirmation step.
public enum ConfirmError: Error, Equatable {
    case selectionNotFound(URL)
    case emptySelection
    case duplicateUUID(UUID)
    case emptyAppleLocale(String)
    case tooManyMeetings(Int)
}

/// Confirms the user's edited selection, assigning meeting IDs and a tamper-detect hash.
public enum Confirm {
    /// Maximum meetings allowed in a single selection.
    public static let maxMeetings = 20

    /// Confirm the selection at the given workspace.
    ///
    /// Reads `selection.json`, validates it, assigns sequential meeting IDs (m01, m02, ...),
    /// computes a confirmation hash, and writes the updated selection back.
    ///
    /// - Parameters:
    ///   - workspace: The workspace directory URL.
    ///   - log: Logger for status output.
    /// - Returns: The confirmed `SelectionFile`.
    @discardableResult
    public static func run(workspace: URL, log: RunLog) throws -> SelectionFile {
        let selectionURL = workspace.appendingPathComponent("selection.json")
        guard FileManager.default.fileExists(atPath: selectionURL.path) else {
            throw ConfirmError.selectionNotFound(selectionURL)
        }

        var selection: SelectionFile = try JSONFiles.read(from: selectionURL)

        // Validate.
        guard !selection.meetings.isEmpty else {
            throw ConfirmError.emptySelection
        }
        guard selection.meetings.count <= maxMeetings else {
            throw ConfirmError.tooManyMeetings(selection.meetings.count)
        }

        var seenUUIDs: Set<UUID> = []
        for entry in selection.meetings {
            guard seenUUIDs.insert(entry.meetingUUID).inserted else {
                throw ConfirmError.duplicateUUID(entry.meetingUUID)
            }
            guard !entry.appleLocale.isEmpty else {
                throw ConfirmError.emptyAppleLocale(entry.title)
            }
        }

        // Assign sequential meeting IDs.
        for i in 0 ..< selection.meetings.count {
            selection.meetings[i].meetingID = String(format: "m%02d", i + 1)
        }

        // Compute confirmation hash.
        selection.confirmedHash = computeHash(meetings: selection.meetings)
        selection.confirmed = true
        selection.confirmedAt = Date()

        // Write back.
        try JSONFiles.write(selection, to: selectionURL)

        // Print summary.
        let totalHours = selection.meetings.reduce(0.0) { $0 + $1.durationSeconds } / 3600
        log.log("Confirmed \(selection.meetings.count) meetings (\(String(format: "%.1f", totalHours)) hours)")
        for entry in selection.meetings {
            let mid = entry.meetingID ?? "?"
            let minutes = Int(entry.durationSeconds / 60)
            log.log("  \(mid): \(entry.title) (\(minutes) min, \(entry.appleLocale))")
        }
        log.log(
            "Audio for these \(selection.meetings.count) meetings "
                + "will be copied to the bundle, and will be uploaded to OpenRouter by `sttlab reference`."
        )

        return selection
    }

    /// Compute the confirmation hash: SHA-256 of the canonical JSON representation
    /// of [(meetingID, meetingUUID, appleLocale)].
    public static func computeHash(meetings: [SelectionEntry]) -> String {
        let entries: [[String: String]] = meetings.map { entry in
            [
                "appleLocale": entry.appleLocale,
                "meetingID": entry.meetingID ?? "",
                "meetingUUID": entry.meetingUUID.uuidString
            ]
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = (try? encoder.encode(entries)) ?? Data()
        let hash = SHA256.hash(data: data)
        return hash.map { String(format: "%02x", $0) }.joined()
    }
}
