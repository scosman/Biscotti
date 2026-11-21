import Foundation

// MARK: - Readable decision log

/// A plain-text log of detection and naming decisions, because the system
/// log doesn't keep the app's routine messages. One app-wide file in the
/// app's support folder (trimmed past 1 MB), and a copy of each meeting's
/// naming lines in its root bundle, deleted with the bundle.
enum MeetingEventLog {
    static let maxBytes = 1_000_000
    static let fileName = "meeting-events.log"

    static var appFile: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Biscotti/\(fileName)")
    }

    /// Only the app writes the log. A test run (not an .app) must never
    /// touch the user's real log or support folder.
    static var isEnabled: Bool {
        Bundle.main.bundlePath.hasSuffix(".app")
    }

    static func write(_ category: String, _ message: String, bundle: URL? = nil) {
        guard isEnabled else { return }
        let stamp = ISO8601DateFormatter.string(from: Date(), timeZone: .current, formatOptions: [.withInternetDateTime])
        let line = "\(stamp) [\(category)] \(message)\n"
        append(line, to: appFile, trimAt: maxBytes)
        if let bundle, FileManager.default.fileExists(atPath: bundle.path) {
            append(line, to: bundle.appendingPathComponent(fileName), trimAt: nil)
        }
    }

    static func append(_ line: String, to url: URL, trimAt limit: Int?) {
        let data = Data(line.utf8)
        let manager = FileManager.default
        try? manager.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        if let limit, let size = (try? manager.attributesOfItem(atPath: url.path))?[.size] as? Int, size > limit,
           let existing = try? Data(contentsOf: url)
        {
            try? existing.suffix(limit / 2).write(to: url)
        }
        guard let handle = try? FileHandle(forWritingTo: url) else {
            try? data.write(to: url)
            return
        }
        defer { try? handle.close() }
        _ = try? handle.seekToEnd()
        try? handle.write(contentsOf: data)
    }
}
