import Foundation

// Data model for UI captures. Foundation-only so the
// redaction, diffing and file format are unit tested on any platform; the
// Accessibility-API reader lives in the macOS-only files.

/// One accessibility element, flattened. Every field is optional so absent
/// attributes cost nothing in the JSON. Short keys keep captures small.
public struct NodeRecord: Codable, Sendable, Equatable {
    /// Path from the window root as child indexes, e.g. "0.3.1". Stable
    /// between snapshots while the layout is unchanged; used as the diff key.
    public var path: String
    public var depth: Int
    public var role: String?
    public var subrole: String?
    public var roleDescription: String?
    public var title: String?
    public var label: String? // AXDescription
    public var value: String?
    public var help: String?
    public var identifier: String? // AXIdentifier
    public var domID: String? // AXDOMIdentifier (web content)
    public var domClasses: [String]? // AXDOMClassList (web content)
    public var frame: [Int]? // x, y, width, height
    public var selected: Bool?
    public var focused: Bool?
    public var enabled: Bool?
    public var bold: Bool? // font trait of the element's text, when exposed
    public var fontWeight: Double? // font weight, when exposed
    public var minValue: Double?
    public var maxValue: Double?
    public var childCount: Int?

    public init(path: String, depth: Int) {
        self.path = path
        self.depth = depth
    }

    /// The fields that change when a UI highlights a speaker, for diffs.
    var dynamicFields: [String: String] {
        var fields: [String: String] = [:]
        fields["title"] = title
        fields["label"] = label
        fields["value"] = value
        fields["help"] = help
        fields["domClasses"] = domClasses?.joined(separator: " ")
        fields["frame"] = frame?.map(String.init).joined(separator: ",")
        fields["selected"] = selected.map { $0 ? "1" : "0" }
        fields["focused"] = focused.map { $0 ? "1" : "0" }
        fields["bold"] = bold.map { $0 ? "1" : "0" }
        fields["fontWeight"] = fontWeight.map { String($0) }
        fields["role"] = role
        fields["childCount"] = childCount.map(String.init)
        return fields
    }
}

/// One line of a capture file.
public enum CaptureRecord: Sendable, Equatable {
    case header(SessionHeader)
    case snapshot(Snapshot)
    case diff(SnapshotDiff)
    case event(UIEvent)
    case note(Note)
}

public struct SessionHeader: Codable, Sendable, Equatable {
    public var formatVersion = 1
    public var startedAt: Date
    /// `ProcessInfo.systemUptime` at session start; every record's
    /// `uptime` is on the same monotonic clock.
    public var startUptime: Double
    public var hostApp: String
    public var macOSVersion: String
    public var targets: [TargetApp]
    /// Biscotti recording in progress when capture started, if any.
    public var recordingMeetingID: UUID?
    public var recordingStartedAt: Date?

    public init(
        startedAt: Date,
        startUptime: Double,
        hostApp: String,
        macOSVersion: String,
        targets: [TargetApp],
        recordingMeetingID: UUID? = nil,
        recordingStartedAt: Date? = nil
    ) {
        self.startedAt = startedAt
        self.startUptime = startUptime
        self.hostApp = hostApp
        self.macOSVersion = macOSVersion
        self.targets = targets
        self.recordingMeetingID = recordingMeetingID
        self.recordingStartedAt = recordingStartedAt
    }
}

public struct TargetApp: Codable, Sendable, Equatable {
    public var bundleID: String
    public var name: String
    public var pid: Int32
    public var version: String?

    public init(bundleID: String, name: String, pid: Int32, version: String? = nil) {
        self.bundleID = bundleID
        self.name = name
        self.pid = pid
        self.version = version
    }
}

/// A full tree of one window.
public struct Snapshot: Codable, Sendable, Equatable {
    public var uptime: Double
    public var bundleID: String
    public var window: String
    public var nodes: [NodeRecord]
    /// How long the walk took, and whether a budget cut it short.
    public var walkMillis: Double
    public var truncated: Bool

    public init(uptime: Double, bundleID: String, window: String, nodes: [NodeRecord], walkMillis: Double, truncated: Bool) {
        self.uptime = uptime
        self.bundleID = bundleID
        self.window = window
        self.nodes = nodes
        self.walkMillis = walkMillis
        self.truncated = truncated
    }
}

/// Changes since the previous snapshot of the same window.
public struct SnapshotDiff: Codable, Sendable, Equatable {
    public struct Change: Codable, Sendable, Equatable {
        public var path: String
        /// New values of the fields that changed; "" means the field went away.
        public var fields: [String: String]
    }

    public var uptime: Double
    public var bundleID: String
    public var window: String
    public var added: [NodeRecord]
    public var removed: [String]
    public var changed: [Change]
    public var walkMillis: Double

    public var isEmpty: Bool {
        added.isEmpty && removed.isEmpty && changed.isEmpty
    }
}

/// An accessibility notification from the target app.
public struct UIEvent: Codable, Sendable, Equatable {
    public var uptime: Double
    public var bundleID: String
    public var name: String
    public var role: String?
    public var title: String?
    public var label: String?
    public var value: String?

    public init(
        uptime: Double, bundleID: String, name: String,
        role: String? = nil, title: String? = nil, label: String? = nil, value: String? = nil
    ) {
        self.uptime = uptime
        self.bundleID = bundleID
        self.name = name
        self.role = role
        self.title = title
        self.label = label
        self.value = value
    }
}

/// Free-form diagnostic line (permission state, mode switches, errors).
public struct Note: Codable, Sendable, Equatable {
    public var uptime: Double
    public var message: String

    public init(uptime: Double, message: String) {
        self.uptime = uptime
        self.message = message
    }
}

// MARK: - Diffing

public enum SnapshotDiffer {
    /// Nodes are matched by `path`. A node whose role changed counts as
    /// removed and re-added, since the layout moved under it.
    public static func diff(from old: Snapshot, to new: Snapshot) -> SnapshotDiff {
        let oldByPath = Dictionary(old.nodes.map { ($0.path, $0) }, uniquingKeysWith: { first, _ in first })
        let newPaths = Set(new.nodes.map(\.path))
        var added: [NodeRecord] = []
        var changed: [SnapshotDiff.Change] = []
        for node in new.nodes {
            guard let previous = oldByPath[node.path], previous.role == node.role else {
                added.append(node)
                continue
            }
            let fields = changedFields(previous.dynamicFields, node.dynamicFields)
            if !fields.isEmpty {
                changed.append(SnapshotDiff.Change(path: node.path, fields: fields))
            }
        }
        let removed = old.nodes.map(\.path).filter { !newPaths.contains($0) }
        return SnapshotDiff(
            uptime: new.uptime, bundleID: new.bundleID, window: new.window,
            added: added, removed: removed, changed: changed, walkMillis: new.walkMillis
        )
    }

    private static func changedFields(_ old: [String: String], _ new: [String: String]) -> [String: String] {
        var result: [String: String] = [:]
        for key in Set(old.keys).union(new.keys) where old[key] != new[key] {
            result[key] = new[key] ?? ""
        }
        return result
    }
}

// MARK: - Redaction

/// Keeps names and labels, drops anything that reads like message text.
///
/// Participant names, button labels and status text are short. Chat
/// messages, documents and transcripts are long or sentence-shaped. Text
/// input fields are always dropped, since they may hold a message being typed.
public enum TextRedactor {
    public static let maxLength = 80
    public static let maxWords = 8

    public static func redact(_ text: String?, role: String?) -> String? {
        guard let text else { return nil }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        if let role, inputRoles.contains(role) {
            return "[input \(trimmed.count) chars]"
        }
        // A participant tile's description ("Ravi Patel,
        // External, video on, muted") is a name and a status list, not prose.
        if let role, statusRoles.contains(role), isPersonStatus(trimmed), trimmed.count <= 240 {
            return trimmed
        }
        if trimmed.count > maxLength || looksLikeProse(trimmed) {
            return "[redacted \(trimmed.count) chars]"
        }
        return trimmed
    }

    /// Roles whose labels describe a participant (tiles, roster rows).
    static let statusRoles: Set<String> = ["AXMenuItem", "AXButton", "AXGroup", "AXImage", "AXCell", "AXRow", "AXListItem"]

    /// "First Last, status, status" or "Last, First, status": a name made
    /// of capitalised words, then short comma-separated parts.
    static func isPersonStatus(_ text: String) -> Bool {
        let parts = text.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
        guard parts.count >= 2, parts.allSatisfy({ $0.split(separator: " ").count <= 5 }) else { return false }
        func capitalised(_ part: String) -> [Substring]? {
            let words = part.split(separator: " ")
            let shaped = !words.isEmpty && words.allSatisfy { $0.first?.isUppercase == true || $0.first == "(" }
            return shaped ? words : nil
        }
        if let first = capitalised(parts[0]), first.count >= 2, first.count <= 4 { return true }
        // "Lopez, Maria (AGENCY), ..."
        if let last = capitalised(parts[0]), last.count == 1, let given = capitalised(parts[1]), given.count <= 2 {
            return parts.count >= 3
        }
        return false
    }

    static let inputRoles: Set<String> = ["AXTextField", "AXTextArea", "AXSearchField", "AXComboBox"]

    /// A container labelled as captions ("Live Captions").
    /// Everything said in it is speech, so only speaker names are kept.
    public static func isCaptionArea(_ node: NodeRecord) -> Bool {
        [node.label, node.title].contains { text in
            guard let text = text?.lowercased() else { return false }
            return text.contains("caption") && !text.contains("redacted")
        }
    }

    /// "[caption 57 chars]": keeps when a caption grows, not what was said.
    public static func captionPlaceholder(_ text: String?) -> String? {
        guard let text, !text.isEmpty else { return text }
        if text.hasPrefix("[redacted "), let count = text.split(separator: " ").dropFirst().first {
            return "[caption \(count) chars]"
        }
        return "[caption \(text.count) chars]"
    }

    /// More than `maxWords` words, or several words ending in sentence
    /// punctuation.
    static func looksLikeProse(_ text: String) -> Bool {
        let words = text.split(whereSeparator: \.isWhitespace)
        if words.count > maxWords {
            return true
        }
        guard words.count >= 4, let last = text.last else { return false }
        return ".?!".contains(last)
    }
}

// MARK: - File format

/// JSON Lines: one record per line, `{"type": "...", "data": {...}}`.
public enum CaptureCoding {
    public static func encodeLine(_ record: CaptureRecord) throws -> Data {
        let encoder = JSONEncoder()
        // Keep milliseconds. Whole seconds left the capture up
        // to a second out of step with the audio.
        encoder.dateEncodingStrategy = .custom { date, encoder in
            var container = encoder.singleValueContainer()
            try container.encode(Self.formatter(fractional: true).string(from: date))
        }
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        var data: Data = switch record {
        case let .header(value): try encoder.encode(Envelope(type: "header", data: value))
        case let .snapshot(value): try encoder.encode(Envelope(type: "snapshot", data: value))
        case let .diff(value): try encoder.encode(Envelope(type: "diff", data: value))
        case let .event(value): try encoder.encode(Envelope(type: "event", data: value))
        case let .note(value): try encoder.encode(Envelope(type: "note", data: value))
        }
        data.append(0x0A)
        return data
    }

    public static func decodeLine(_ line: Data) throws -> CaptureRecord {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            let text = try decoder.singleValueContainer().decode(String.self)
            if let date = Self.formatter(fractional: true).date(from: text) ?? Self.formatter(fractional: false).date(from: text) {
                return date
            }
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "Bad date \(text)"))
        }
        let kind = try decoder.decode(Kind.self, from: line).type
        switch kind {
        case "header": return try .header(decoder.decode(Envelope<SessionHeader>.self, from: line).data)
        case "snapshot": return try .snapshot(decoder.decode(Envelope<Snapshot>.self, from: line).data)
        case "diff": return try .diff(decoder.decode(Envelope<SnapshotDiff>.self, from: line).data)
        case "event": return try .event(decoder.decode(Envelope<UIEvent>.self, from: line).data)
        default: return try .note(decoder.decode(Envelope<Note>.self, from: line).data)
        }
    }

    /// ISO 8601, with or without milliseconds (older captures have none).
    static func formatter(fractional: Bool) -> ISO8601DateFormatter {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = fractional ? [.withInternetDateTime, .withFractionalSeconds] : [.withInternetDateTime]
        return formatter
    }

    private struct Envelope<Payload: Codable>: Codable {
        var type: String
        var data: Payload
    }

    private struct Kind: Codable {
        var type: String
    }
}

/// Appends records to a capture file and enforces a size cap.
public final class CaptureWriter {
    public let url: URL
    public let maxBytes: Int
    public private(set) var bytesWritten = 0
    private let handle: FileHandle

    public init(url: URL, maxBytes: Int = 200_000_000) throws {
        self.url = url
        self.maxBytes = maxBytes
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        guard FileManager.default.createFile(atPath: url.path, contents: nil) else {
            throw CocoaError(.fileWriteUnknown)
        }
        handle = try FileHandle(forWritingTo: url)
    }

    /// Whether the size cap has been reached; later writes are dropped.
    public var isFull: Bool {
        bytesWritten >= maxBytes
    }

    public func write(_ record: CaptureRecord) throws {
        guard !isFull else { return }
        let line = try CaptureCoding.encodeLine(record)
        try handle.write(contentsOf: line)
        bytesWritten += line.count
    }

    public func close() {
        try? handle.close()
    }

    /// `ui-capture 2026-11-17 1502.jsonl`
    public static func fileName(for date: Date, timeZone: TimeZone = .current) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = timeZone
        formatter.dateFormat = "yyyy-MM-dd HHmmss"
        return "ui-capture \(formatter.string(from: date)).jsonl"
    }
}
