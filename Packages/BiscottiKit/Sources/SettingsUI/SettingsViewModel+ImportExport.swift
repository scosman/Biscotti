import AppCore
import AppKit
import DataStore
import Foundation
import ImportExport
import UniformTypeIdentifiers

/// Drives the Import/Export section's `.alert` (architecture §6.1).
/// `.result` and `.failure` carry their own titles so the import and
/// debug-delete outcomes (and the import vs export failures) can each
/// name themselves; otherwise this matches the architecture sketch.
enum ImportAlertState: Equatable, Identifiable {
    /// Critical errors. Single dismiss button; nothing is imported
    /// (functional spec §3.3).
    case blocked(title: String, body: String)
    /// Warnings only. Cancel (default action) / Continue.
    case review(body: String)
    /// Post-commit summary or debug-delete outcome (functional spec §3.4).
    case result(title: String, body: String)
    /// Commit, export, or save failure (architecture §8).
    case failure(title: String, body: String)
    #if DEBUG
        /// Debug bulk-delete confirmation (functional spec §6.1). Cancel
        /// (default) / Delete (destructive).
        case confirmDeleteImported(title: String, body: String)
    #endif

    var id: String {
        switch self {
        case let .blocked(title, body): "blocked|\(title)|\(body)"
        case let .review(body): "review|\(body)"
        case let .result(title, body): "result|\(title)|\(body)"
        case let .failure(title, body): "failure|\(title)|\(body)"
        #if DEBUG
            case let .confirmDeleteImported(title, body):
                "confirmDelete|\(title)|\(body)"
        #endif
        }
    }
}

extension ImportAlertState {
    /// The review alert's title. Lives here (not on the @MainActor view
    /// model) because `title` is read from this nonisolated enum.
    static let reviewTitle = "Import This File?"

    /// The alert title. `.review` has no payload title — it always asks
    /// the same question.
    var title: String {
        switch self {
        case let .blocked(title, _),
             let .result(title, _),
             let .failure(title, _):
            title
        case .review:
            Self.reviewTitle
        #if DEBUG
            case let .confirmDeleteImported(title, _):
                title
        #endif
        }
    }

    /// The alert body text.
    var body: String {
        switch self {
        case let .blocked(_, body),
             let .result(_, body),
             let .failure(_, body):
            body
        case let .review(body):
            body
        #if DEBUG
            case let .confirmDeleteImported(_, body):
                body
        #endif
        }
    }

    #if DEBUG
        /// True only for the debug delete confirmation. The Import/Export
        /// section's alert modifier excludes this state; the Debug
        /// section's own modifier presents it — the two never double-fire.
        var isDeleteConfirmation: Bool {
            if case .confirmDeleteImported = self { return true }
            return false
        }
    #endif
}

// MARK: - Import/Export actions

public extension SettingsViewModel {
    /// Runs the import flow (functional spec §2.1): open panel → scan →
    /// blocked / review / commit straight through. Nothing is written
    /// before the user clears the review alert.
    func beginImport() async {
        guard !importExportBusy else { return }
        importExportBusy = true
        importInFlight = true
        defer {
            importExportBusy = false
            importInFlight = false
        }

        guard let url = presentOpenPanel() else { return }
        let result = await appCore.scanMeetingImport(at: url)

        if !result.criticalErrors.isEmpty {
            importAlert = .blocked(
                title: Self.importBlockedTitle,
                body: Self.blockedBody(for: result)
            )
            return
        }
        if result.needsReview {
            pendingImport = result
            importAlert = .review(body: Self.reviewBody(for: result))
            return
        }

        // No errors and no warnings. This deliberately includes the
        // header-only file (valid header, zero data rows), which scans
        // clean with zero drafts: the commit inserts nothing and reports
        // "Imported 0 meetings" (functional spec §3.3/§3.4).
        await commitImport(result)
    }

    /// Continue from the review alert: commits the held scan result
    /// exactly as scanned (functional spec §2.1 step 3).
    func confirmImport() async {
        guard !importExportBusy, let result = pendingImport else { return }
        pendingImport = nil
        importExportBusy = true
        importInFlight = true
        defer {
            importExportBusy = false
            importInFlight = false
        }
        await commitImport(result)
    }

    /// Cancel from the review alert: drops the held scan result without
    /// writing anything.
    func cancelImportReview() {
        pendingImport = nil
        importAlert = nil
    }

    /// Runs the export flow (functional spec §5.2): spinner → generate
    /// off the main actor → save panel → move, or delete the temp file.
    func beginExport() async {
        guard !importExportBusy else { return }
        importExportBusy = true
        exportInFlight = true
        defer {
            importExportBusy = false
            exportInFlight = false
        }

        let tempURL: URL
        do {
            tempURL = try await appCore.exportMeetingsCSV()
        } catch {
            importAlert = .failure(
                title: Self.exportFailedTitle,
                body: "The export failed: \(Self.detail(for: error))."
            )
            return
        }

        // The spinner clears before the save dialog opens (functional
        // spec §5.2); importExportBusy stays raised until the move
        // settles so neither button can start a second operation.
        exportInFlight = false
        finishExport(tempURL)
    }

    /// Clears the presented alert (the alert-dismissal binding).
    func dismissImportAlert() {
        importAlert = nil
    }
}

extension SettingsViewModel {
    func commitImport(_ result: ImportScanResult) async {
        do {
            let summary = try await appCore.commitMeetingImport(result)
            importAlert = .result(
                title: Self.importResultTitle,
                body: Self.resultBody(for: summary)
            )
        } catch {
            importAlert = .failure(
                title: Self.importFailedTitle,
                body: "The import failed: \(Self.detail(for: error))."
            )
        }
    }

    func finishExport(_ tempURL: URL) {
        guard let destination = presentSavePanel(tempURL.lastPathComponent)
        else {
            // Cancelling the save panel is not an error; the temp file
            // is deleted (functional spec §5.2).
            try? FileManager.default.removeItem(at: tempURL)
            return
        }

        do {
            if FileManager.default.fileExists(atPath: destination.path()) {
                // The save panel already asked about replacing an existing
                // file, so the replacement is confirmed. replaceItemAt
                // keeps the original intact when the swap fails (disk
                // full, volume error) — the user confirmed replacing the
                // old file, not losing it.
                // The returned URL (where the new item landed) is
                // deliberately ignored: on the local filesystem it is
                // the destination itself.
                _ = try FileManager.default.replaceItemAt(
                    destination, withItemAt: tempURL
                )
                // A successful replace consumes the new item; a
                // cross-volume swap may have copied it instead, so clean
                // up best-effort.
                try? FileManager.default.removeItem(at: tempURL)
            } else {
                try FileManager.default.moveItem(at: tempURL, to: destination)
            }
        } catch {
            importAlert = .failure(
                title: Self.exportFailedTitle,
                body: "The file could not be saved: \(error.localizedDescription)."
            )
            // A failed move still consumes the temp file (architecture §8).
            try? FileManager.default.removeItem(at: tempURL)
        }
    }
}

// MARK: - Live panels (functional spec §6, §5.2)

extension SettingsViewModel {
    /// Live open panel: `.csv` files only, single selection.
    @MainActor
    static func presentCSVOpenPanel() -> URL? {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.commaSeparatedText]
        panel.allowsMultipleSelection = false
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        guard panel.runModal() == .OK else { return nil }
        return panel.url
    }

    /// Live save panel, pre-filled with the generated export filename.
    @MainActor
    static func presentCSVSavePanel(fileName: String) -> URL? {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = fileName
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK else { return nil }
        return panel.url
    }
}

// MARK: - Alert copy (verbatim-identity policy: these statics == the spec text)

extension SettingsViewModel {
    static let importBlockedTitle = "Cannot Import This File"
    static let importResultTitle = "Import Complete"
    static let importFailedTitle = "Import Failed"
    static let exportFailedTitle = "Export Failed"

    /// Body for the blocking alert: each distinct problem with its count
    /// and up to 5 example row numbers (functional spec §3.3).
    static func blockedBody(for result: ImportScanResult) -> String {
        result.criticalErrors.map(\.message).joined(separator: "\n")
    }

    /// Body for the review alert: each warning with its count, then how
    /// many meetings will actually be imported (functional spec §3.3).
    static func reviewBody(for result: ImportScanResult) -> String {
        let noun = result.drafts.count == 1 ? "meeting" : "meetings"
        return result.warnings.map(\.message).joined(separator: "\n")
            + "\n\n\(result.drafts.count) \(noun) will be imported."
    }

    /// Body for the result alert (functional spec §3.4).
    static func resultBody(for summary: ImportCommitSummary) -> String {
        var lines = [
            "Imported \(summary.imported) "
                + (summary.imported == 1 ? "meeting" : "meetings") + "."
        ]
        if summary.skippedExisting > 0 {
            lines.append(
                "\(summary.skippedExisting) "
                    + (summary.skippedExisting == 1 ? "row was" : "rows were")
                    + " skipped because those meetings already exist."
            )
        }
        if summary.skippedMisformatted > 0 {
            lines.append(
                "\(summary.skippedMisformatted) "
                    + (summary.skippedMisformatted == 1 ? "row was" : "rows were")
                    + " skipped because they were missing a required value."
            )
        }
        return lines.joined(separator: "\n")
    }

    /// A short, user-facing reason for a store or exporter error.
    static func detail(for error: Error) -> String {
        switch error {
        case let CSVExportError.cannotCreateFile(path):
            "the temporary file could not be created at \(path)"
        case let DataStoreError.saveFailed(reason):
            reason
        default:
            error.localizedDescription
        }
    }
}

// MARK: - Debug: Delete Imported Meetings (functional spec §6.1)

#if DEBUG
    extension SettingsViewModel {
        /// Counts imported meetings and either presents the confirmation
        /// (exact copy: "Delete N meetings?" / "This will delete N
        /// meetings (and leave M meetings).") or, when there are none,
        /// the "No imported meetings to delete." result.
        func promptDeleteImportedMeetings() async {
            let counts = await appCore.importedMeetingCounts()
            guard counts.imported > 0 else {
                importAlert = .result(
                    title: Self.deleteImportedAlertTitle,
                    body: Self.deleteImportedNoneBody
                )
                return
            }
            importAlert = .confirmDeleteImported(
                title: "Delete \(counts.imported) meetings?",
                body: "This will delete \(counts.imported) meetings "
                    + "(and leave \(counts.remaining) meetings)."
            )
        }

        /// Delete from the confirmation: deletes, refreshes, and reports
        /// "Deleted N meetings."
        func confirmDeleteImportedMeetings() async {
            do {
                let deleted = try await appCore.deleteImportedMeetings()
                importAlert = .result(
                    title: Self.deleteImportedAlertTitle,
                    body: "Deleted \(deleted) "
                        + (deleted == 1 ? "meeting" : "meetings") + "."
                )
            } catch {
                importAlert = .failure(
                    title: Self.deleteImportedAlertTitle,
                    body: "The delete failed: \(Self.detail(for: error))."
                )
            }
        }
    }

    extension SettingsViewModel {
        static let deleteImportedAlertTitle = "Delete Imported Meetings"
        static let deleteImportedNoneBody = "No imported meetings to delete."
    }
#endif
