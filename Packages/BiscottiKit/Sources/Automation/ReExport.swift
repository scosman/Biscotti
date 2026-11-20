import Foundation

/// What to do with automatic exports after a re-transcription,
/// chosen by the user when they start it.
public enum ReExportChoice: String, Sendable, Equatable {
    /// Export and overwrite the meeting's current export file.
    case replace
    /// Rename the current file to "... (before <date>).md", then export.
    case keepBoth
    /// Leave exports alone.
    case skip
}

/// The setting for what re-transcribing does to exports.
public enum ReTranscribeExportBehavior: String, Codable, Sendable, CaseIterable, Identifiable {
    case ask
    case replace
    case keepOld
    case skip

    public var id: String {
        rawValue
    }

    public var title: String {
        switch self {
        case .ask: "Ask each time"
        case .replace: "Replace the export"
        case .keepOld: "Keep the old export and add the new one"
        case .skip: "Don't export"
        }
    }

    /// The choice to apply without asking, or nil to ask.
    public var automaticChoice: ReExportChoice? {
        switch self {
        case .ask: nil
        case .replace: .replace
        case .keepOld: .keepBoth
        case .skip: .skip
        }
    }
}

public extension MeetingExporter {
    /// Existing export files for a meeting in the given targets (matched by
    /// the meeting's ID marker).
    static func existingExports(meetingID: UUID, in targets: [ExportTarget]) -> [URL] {
        let marker = MeetingMarkdown.idMarker(for: meetingID)
        var found: [URL] = []
        for target in targets {
            let directory = target.outputDirectory
            let names = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
            for name in names where name.hasSuffix("\(marker).md") {
                found.append(directory.appendingPathComponent(name))
            }
        }
        return found
    }

    /// Renames a meeting's current export files so the next export can't
    /// replace them: "2026-11-18 1129 Title [1a2b3c4d].md" becomes
    /// "2026-11-18 1129 Title [1a2b3c4d] (before 2026-11-18 1530).md". The
    /// renamed file no longer ends with the ID marker, so later exports
    /// leave it alone. Returns the new URLs.
    @discardableResult
    static func preserveExistingExports(
        meetingID: UUID,
        in targets: [ExportTarget],
        now: Date = Date(),
        timeZone: TimeZone = .current
    ) throws -> [URL] {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = timeZone
        formatter.dateFormat = "yyyy-MM-dd HHmm"
        let stamp = formatter.string(from: now)
        var renamed: [URL] = []
        for file in existingExports(meetingID: meetingID, in: targets) {
            let base = file.deletingPathExtension().lastPathComponent
            var destination = file.deletingLastPathComponent()
                .appendingPathComponent("\(base) (before \(stamp)).md")
            var counter = 2
            while FileManager.default.fileExists(atPath: destination.path) {
                destination = file.deletingLastPathComponent()
                    .appendingPathComponent("\(base) (before \(stamp) \(counter)).md")
                counter += 1
            }
            try FileManager.default.moveItem(at: file, to: destination)
            renamed.append(destination)
        }
        return renamed
    }
}
