import Foundation
import STTLabCore

/// Errors from the consent gate.
public enum ConsentGateError: Error, Equatable {
    case selectionNotFound(URL)
    case notConfirmed
    case hashMismatch
}

/// Validates that the selection has been confirmed and has not been tampered with.
/// Used by bundle, whisper, diarize, and reference commands before doing work.
public enum ConsentGate {
    /// Check that the selection is confirmed and its hash is valid.
    ///
    /// - Parameter workspace: The workspace directory URL.
    /// - Returns: The validated `SelectionFile`.
    /// - Throws: `ConsentGateError` if the selection is missing, not confirmed,
    ///   or has been modified after confirmation.
    @discardableResult
    public static func require(workspace: URL) throws -> SelectionFile {
        let selectionURL = workspace.appendingPathComponent("selection.json")
        guard FileManager.default.fileExists(atPath: selectionURL.path) else {
            throw ConsentGateError.selectionNotFound(selectionURL)
        }

        let selection: SelectionFile = try JSONFiles.read(from: selectionURL)

        guard selection.confirmed else {
            throw ConsentGateError.notConfirmed
        }

        // Recompute and verify the hash.
        let expected = Confirm.computeHash(meetings: selection.meetings)
        guard selection.confirmedHash == expected else {
            throw ConsentGateError.hashMismatch
        }

        return selection
    }
}
