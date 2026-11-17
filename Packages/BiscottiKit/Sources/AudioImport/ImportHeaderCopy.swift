import Foundation

/// The Import screen's header title and status line, computed as a pure
/// function from session state.
public struct ImportHeaderCopy: Equatable, Sendable {
    public let title: String
    public let status: String
    /// In-progress status uses monospace font.
    public let statusIsMono: Bool

    public init(title: String, status: String, statusIsMono: Bool) {
        self.title = title
        self.status = status
        self.statusIsMono = statusIsMono
    }

    /// Computes the header copy from the current session state.
    public static func make(
        items: [ImportItem],
        run: ImportRun?,
        runPosition: Int?
    ) -> ImportHeaderCopy {
        if let run {
            // In progress
            let count = run.count
            let title = "Importing \(filePlural(count))"
            let status: String
            if count == 1 {
                status = "converting audio"
            } else {
                let pos = runPosition ?? 1
                status = "\(pos) of \(count) \u{00B7} converting audio"
            }
            return ImportHeaderCopy(
                title: title, status: status, statusIsMono: true
            )
        }

        // Complete
        let total = items.count
        let doneCount = items.count(where: {
            if case .done = $0.status { return true }
            return false
        })

        if doneCount == total {
            // All succeeded
            let title = "Imported \(filePlural(total))"
            let status =
                "Transcripts and summaries are being written in each meeting."
            return ImportHeaderCopy(
                title: title, status: status, statusIsMono: false
            )
        } else if doneCount > 0 {
            // Some failed
            let title = "Imported \(doneCount) of \(total) files"
            let status =
                "Transcripts and summaries are being written in each meeting."
            return ImportHeaderCopy(
                title: title, status: status, statusIsMono: false
            )
        } else {
            // All failed
            let title = "Imported 0 of \(filePlural(total))"
            let status = total == 1
                ? "Couldn't convert this file."
                : "Couldn't convert these files."
            return ImportHeaderCopy(
                title: title, status: status, statusIsMono: false
            )
        }
    }

    private static func filePlural(_ count: Int) -> String {
        "\(count) " + (count == 1 ? "file" : "files")
    }
}
