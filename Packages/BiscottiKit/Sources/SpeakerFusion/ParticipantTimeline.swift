import Foundation
import UICapture

// Turns a UI capture file into "who was highlighted when",
// in recording seconds. Nothing here knows Teams' or Zoom's markup. An
// element that flips between a few visual states (CSS classes, bold, a
// level value) and sits under something labelled with a person's name is
// treated as that person's speaking indicator; its rarer state is "speaking".

/// One stretch of time a participant's speaking indicator was on.
public struct SpeakingInterval: Sendable, Equatable {
    public var name: String
    public var start: Double
    public var end: Double

    public init(name: String, start: Double, end: Double) {
        self.name = name
        self.start = start
        self.end = end
    }

    func overlap(_ lower: Double, _ upper: Double) -> Double {
        max(0, min(end, upper) - max(start, lower))
    }
}

public struct ParticipantTimeline: Sendable, Equatable {
    /// Speaking intervals in recording seconds, sorted by start.
    public var intervals: [SpeakingInterval]
    /// Every person name seen on an element that changed state.
    public var participants: [String]
    /// Highlights dropped because the person was shown as muted.
    public var mutedHighlightsDropped: Int
    /// Live captions with their text, in recording seconds.
    public var captions: [CaptionLine]
    /// When the call ended, in recording seconds: the last
    /// tick of the call timer or sighting of a Leave/End button, when the
    /// capture kept running well past it. Nil when it can't be told.
    public var callEndedAt: Double?
    /// Every name shown in a meeting window (participant
    /// tiles, roster), whether or not they were seen speaking.
    public var seen: [String] = []

    public init(
        intervals: [SpeakingInterval], participants: [String], mutedHighlightsDropped: Int = 0,
        captions: [CaptionLine] = []
    ) {
        self.intervals = intervals.sorted { $0.start < $1.start }
        self.participants = participants
        self.mutedHighlightsDropped = mutedHighlightsDropped
        self.captions = captions
        callEndedAt = nil
    }

    public static let empty = ParticipantTimeline(intervals: [], participants: [])

    public var isEmpty: Bool {
        intervals.isEmpty
    }

    /// Seconds each named person's indicator overlaps `[from, to]`.
    func overlaps(from lower: Double, until upper: Double, excluding excluded: Set<String>) -> [String: Double] {
        var result: [String: Double] = [:]
        for interval in intervals where interval.start < upper && interval.end > lower {
            // "Carter, Sam" and "Sam Carter" are the same person.
            guard !excluded.contains(where: { PersonName.same($0, interval.name) }) else { continue }
            result[interval.name, default: 0] += interval.overlap(lower, upper)
        }
        return result
    }
}

public enum ParticipantTimelineBuilder {
    /// Reads a capture file and builds the timeline.
    /// - Parameter recordingStartedAt: When the audio starts. Used when the
    ///   capture header doesn't name it (older or manually started captures).
    public static func build(captureFile url: URL, recordingStartedAt: Date?) throws -> ParticipantTimeline {
        let data = try Data(contentsOf: url)
        var records: [CaptureRecord] = []
        records.reserveCapacity(4096)
        for line in data.split(separator: 0x0A, omittingEmptySubsequences: true) {
            if let record = try? CaptureCoding.decodeLine(Data(line)) {
                records.append(record)
            }
        }
        return build(records: records, recordingStartedAt: recordingStartedAt)
    }

    public static func build(records: [CaptureRecord], recordingStartedAt: Date?) -> ParticipantTimeline {
        var replay = Replay()
        for record in records {
            replay.apply(record)
        }
        guard let header = replay.header else { return .empty }
        let audioStart = header.recordingStartedAt ?? recordingStartedAt ?? header.startedAt
        let offset = header.startedAt.timeIntervalSince(audioStart) - header.startUptime
        return replay.timeline(timeOffset: offset)
    }

    /// The capture file for a recording: one whose header names the meeting,
    /// otherwise the untagged one (started by hand) whose time span covers
    /// most of the recording. A capture tagged for another meeting is never
    /// borrowed.
    public static func findCapture(
        in folder: URL,
        meetingID: UUID,
        recordingStart: Date,
        recordingEnd: Date
    ) -> URL? {
        let files = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.contentModificationDateKey]))?
            .filter { $0.lastPathComponent.hasPrefix("ui-capture") && $0.pathExtension == "jsonl" } ?? []
        var best: (url: URL, overlap: Double)?
        for file in files {
            guard let header = readHeader(file) else { continue }
            if header.recordingMeetingID == meetingID {
                return file
            }
            guard header.recordingMeetingID == nil else { continue }
            let modified = (try? file.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
            let end = modified ?? header.startedAt
            let overlap = min(end, recordingEnd).timeIntervalSince(max(header.startedAt, recordingStart))
            if overlap > 10, overlap > (best?.overlap ?? 0) {
                best = (file, overlap)
            }
        }
        return best?.url
    }

    static func readHeader(_ url: URL) -> SessionHeader? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        guard let chunk = try? handle.read(upToCount: 64 * 1024),
              let line = chunk.split(separator: 0x0A).first,
              case let .header(header)? = try? CaptureCoding.decodeLine(Data(line))
        else { return nil }
        return header
    }
}

// MARK: - Replay

private struct NodeKey: Hashable {
    var window: String
    var path: String

    var parent: NodeKey? {
        guard let dot = path.lastIndex(of: ".") else { return nil }
        return NodeKey(window: window, path: String(path[..<dot]))
    }
}

/// A caption row changed: its speaker (`name`) or its words.
private struct CaptionEvent {
    var entry: NodeKey
    var name: String?
    var text: String?
}

private struct LiveNode {
    var role: String?
    var label: String?
    var title: String?
    var value: String?
    var visual: String = ""
}

private struct Replay {
    var header: SessionHeader?
    var nodes: [NodeKey: LiveNode] = [:]
    /// Visual-state history of every node, raw uptime.
    var visualHistory: [NodeKey: [(Double, String)]] = [:]
    /// Text history of every node with a name-like label, raw uptime.
    var textHistory: [NodeKey: [(Double, String)]] = [:]
    var lastUptime: Double = 0
    /// Containers labelled as captions.
    var captionRoots: Set<NodeKey> = []
    /// The speaker currently shown on each caption entry.
    var captionNames: [NodeKey: String] = [:]
    /// Moments a caption grew, raw uptime.
    var captionPings: [(time: Double, name: String)] = []
    /// Caption lines with text, raw uptime; and the line each
    /// caption row is currently showing.
    var captionLines: [CaptionLine] = []
    var openLine: [NodeKey: Int] = [:]
    /// Titles of windows and web areas (never a person), and
    /// the last sign the call was live (raw uptime).
    var windowTitles: Set<String> = []
    var lastCallSign: Double?
    /// Leave/End buttons on screen, and the last time one went away.
    var callSignNodes: Set<NodeKey> = []
    var callSignGoneAt: Double?
    /// When the app said the meeting ended ("Meeting in "General" ended").
    var endedNoticeAt: Double?
    /// Last snapshot or change seen in each window (raw uptime).
    var windowLastSeen: [String: Double] = [:]
    /// Names shown per window, and the windows that held a call.
    var seenNames: [String: Set<String>] = [:]
    var callWindows: Set<String> = []

    mutating func apply(_ record: CaptureRecord) {
        switch record {
        case let .header(value):
            header = value
            lastUptime = value.startUptime
        case let .snapshot(snapshot):
            applySnapshot(snapshot)
        case let .diff(diff):
            applyDiff(diff)
        case let .event(event):
            lastUptime = max(lastUptime, event.uptime)
            if let value = event.value, ParticipantTimelineBuilder.isCallTimer(value) {
                lastCallSign = max(lastCallSign ?? 0, event.uptime)
            } else if let value = event.value, ParticipantTimelineBuilder.isEndedNotice(value) {
                endedNoticeAt = max(endedNoticeAt ?? 0, event.uptime)
            }
        case let .note(note):
            lastUptime = max(lastUptime, note.uptime)
        }
    }

    mutating func applySnapshot(_ snapshot: Snapshot) {
        lastUptime = max(lastUptime, snapshot.uptime)
        let title = Self.windowName(snapshot.window)
        guard !ParticipantTimelineBuilder.isNonMeetingWindow(title) else { return }
        let window = Self.windowKey(bundleID: snapshot.bundleID, title: title)
        windowLastSeen[window] = snapshot.uptime
        let present = Set(snapshot.nodes.map(\.path))
        for key in nodes.keys where key.window == window {
            if !present.contains(key.path) {
                nodeGone(key, at: snapshot.uptime)
            }
            nodes[key] = nil
        }
        for node in snapshot.nodes {
            add(node, window: window, at: snapshot.uptime)
        }
        seedCaptionNames(snapshot.nodes, window: window)
    }

    mutating func applyDiff(_ diff: SnapshotDiff) {
        lastUptime = max(lastUptime, diff.uptime)
        let title = Self.windowName(diff.window)
        guard !ParticipantTimelineBuilder.isNonMeetingWindow(title) else { return }
        let window = Self.windowKey(bundleID: diff.bundleID, title: title)
        windowLastSeen[window] = diff.uptime
        for path in diff.removed {
            let key = NodeKey(window: window, path: path)
            nodeGone(key, at: diff.uptime)
            nodes[key] = nil
        }
        var events: [CaptionEvent] = []
        for node in diff.added {
            add(node, window: window, at: diff.uptime)
            events += captionEvent(path: node.path, role: node.role, value: node.value, window: window)
        }
        for change in diff.changed {
            update(change, window: window, at: diff.uptime)
            let role = nodes[NodeKey(window: window, path: change.path)]?.role
            events += captionEvent(path: change.path, role: role, value: change.fields["value"], window: window)
        }
        applyCaptions(events, at: diff.uptime)
    }

    mutating func add(_ node: NodeRecord, window: String, at time: Double) {
        let key = NodeKey(window: window, path: node.path)
        var live = LiveNode(role: node.role, label: node.label, title: node.title, value: node.value)
        live.visual = Self.visual(
            classes: node.domClasses?.joined(separator: " "),
            bold: node.bold.map { $0 ? "1" : "0" },
            weight: node.fontWeight.map { String($0) },
            role: node.role, value: node.value
        )
        nodes[key] = live
        record(key, live, at: time)
    }

    mutating func update(_ change: SnapshotDiff.Change, window: String, at time: Double) {
        let key = NodeKey(window: window, path: change.path)
        var live = nodes[key] ?? LiveNode()
        let fields = change.fields
        if let value = fields["label"] { live.label = value.isEmpty ? nil : value }
        if let value = fields["title"] { live.title = value.isEmpty ? nil : value }
        if let value = fields["value"] { live.value = value.isEmpty ? nil : value }
        if let value = fields["role"] { live.role = value.isEmpty ? nil : value }
        let previous = live.visual.split(separator: "|", omittingEmptySubsequences: false).map(String.init)
        func old(_ index: Int) -> String? {
            index < previous.count ? previous[index] : nil
        }
        live.visual = Self.visual(
            classes: fields["domClasses"] ?? old(0),
            bold: fields["bold"] ?? old(1),
            weight: fields["fontWeight"] ?? old(2),
            role: live.role, value: live.value
        )
        nodes[key] = live
        record(key, live, at: time)
    }

    mutating func record(_ key: NodeKey, _ live: LiveNode, at time: Double) {
        // A caption's words are speech, not a name ("Yes, Sir."); only its
        // first child (the speaker) can be one.
        let captionText = isInCaptions(key) && !key.path.hasSuffix(".0")
        if live.role == "AXStaticText" || live.role == "AXMenuItem", !captionText,
           let name = (live.value ?? live.label ?? live.title).flatMap(PersonName.parse)
        {
            seenNames[key.window, default: []].insert(name)
        }
        if live.role == "AXWindow" || live.role == "AXWebArea" {
            for text in [live.title, live.label].compactMap(\.self) {
                windowTitles.insert(text)
            }
        }
        if live.role == "AXButton", let label = (live.label ?? live.title)?.lowercased(),
           ["leave", "hang up", "end call", "end"].contains(label)
        {
            lastCallSign = max(lastCallSign ?? 0, time)
            callWindows.insert(key.window)
            callSignNodes.insert(key)
            // Back on screen (Zoom hides its controls when the mouse rests):
            // an earlier disappearance no longer says the call ended.
            if let gone = callSignGoneAt, gone <= time { callSignGoneAt = nil }
        } else if callSignNodes.contains(key) {
            // The button changed into something else: the call control left.
            callSignNodes.remove(key)
            callSignGoneAt = max(callSignGoneAt ?? 0, time)
        }
        if [live.label, live.title].contains(where: { $0?.lowercased().contains("caption") == true }) {
            captionRoots.insert(key)
        }
        var history = visualHistory[key, default: []]
        if history.last?.1 != live.visual {
            history.append((time, live.visual))
            visualHistory[key] = history
        }
        for text in [live.label, live.title, live.value].compactMap(\.self) where PersonName.parse(text) != nil {
            var texts = textHistory[key, default: []]
            if texts.last?.1 != text {
                texts.append((time, text))
                textHistory[key] = texts
            }
            break
        }
    }

    /// The nearest node at or above `key` (up to 8 levels) carrying a name.
    func namedAncestor(of key: NodeKey) -> NodeKey? {
        var current: NodeKey? = key
        var steps = 0
        while let candidate = current, steps <= 8 {
            if textHistory[candidate] != nil {
                return candidate
            }
            current = candidate.parent
            steps += 1
        }
        return nil
    }

    func text(of key: NodeKey, at time: Double) -> String? {
        guard let history = textHistory[key] else { return nil }
        return history.last { $0.0 <= time + 0.05 }?.1 ?? history.first?.1
    }

    func timeline(timeOffset: Double) -> ParticipantTimeline {
        var intervals: [SpeakingInterval] = []
        var participants: [String] = []
        var muted = 0
        for (key, history) in visualHistory {
            guard history.count >= 3, !isInCaptions(key), let owner = namedAncestor(of: key),
                  !isInCaptions(owner) else { continue }
            let spans = Self.spans(history, end: lastUptime).filter { $0.state != Self.gone }
            var totals: [String: Double] = [:]
            for span in spans {
                totals[span.state, default: 0] += span.end - span.start
            }
            guard totals.count >= 2, let baseline = totals.max(by: { $0.value < $1.value })?.key else { continue }
            let total = totals.values.reduce(0, +)
            guard total > 0, (total - totals[baseline, default: 0]) / total < 0.6 else { continue }
            for span in spans where span.state != baseline && span.end - span.start <= 90 {
                let middle = (span.start + span.end) / 2
                guard let text = text(of: owner, at: middle), let name = PersonName.parse(text) else { continue }
                if PersonName.isMuted(text) {
                    muted += 1
                    continue
                }
                if !participants.contains(name) {
                    participants.append(name)
                }
                intervals.append(SpeakingInterval(
                    name: name, start: span.start + timeOffset, end: span.end + timeOffset
                ))
            }
        }
        let captioned = captionIntervals(timeOffset: timeOffset)
        let names = Set(participants).union(captioned.map(\.name))
        var timeline = ParticipantTimeline(
            intervals: Self.merge(intervals + captioned), participants: names.sorted(), mutedHighlightsDropped: muted
        )
        // A window's title is never a person
        // ("Fabrikam Holdings IT Project").
        let titles = Set(windowTitles.compactMap(PersonName.parse))
        timeline.intervals.removeAll { titles.contains($0.name) }
        timeline.participants.removeAll { titles.contains($0) }
        // Only call windows: an idle Dialpad window lists your contacts.
        let shown = callWindows.reduce(into: Set<String>()) { $0.formUnion(seenNames[$1] ?? []) }
        timeline.seen = shown.subtracting(titles).sorted()
        if let sign = lastCallSign, callEndConfirmed(after: sign) {
            timeline.callEndedAt = sign + timeOffset
        }
        timeline.captions = captionLines.map { line in
            var shifted = line
            shifted.start += timeOffset
            shifted.end += timeOffset
            return shifted
        }
        return timeline
    }

    /// The capture has to run this long past the last call sign to say the
    /// call ended.
    static let callEndMargin = 10.0
    /// Visual state of a node that has left the screen.
    static let gone = "\u{0}gone"

    static let captionLead = 2.5
    static let captionTail = 0.0
}

// MARK: - Window names, visual state and spans

extension Replay {
    struct Span {
        var start: Double
        var end: Double
        var state: String
    }

    static func spans(_ history: [(Double, String)], end: Double) -> [Span] {
        var result: [Span] = []
        for (index, entry) in history.enumerated() {
            let next = index + 1 < history.count ? history[index + 1].0 : max(end, entry.0)
            result.append(Span(start: entry.0, end: next, state: entry.1))
        }
        return result
    }

    /// Union of overlapping intervals per person (tile + roster row).
    static func merge(_ intervals: [SpeakingInterval]) -> [SpeakingInterval] {
        var result: [SpeakingInterval] = []
        for name in Set(intervals.map(\.name)) {
            let sorted = intervals.filter { $0.name == name }.sorted { $0.start < $1.start }
            var current: SpeakingInterval?
            for interval in sorted {
                if var open = current, interval.start <= open.end + 0.05 {
                    open.end = max(open.end, interval.end)
                    current = open
                } else {
                    if let open = current { result.append(open) }
                    current = interval
                }
            }
            if let open = current { result.append(open) }
        }
        return result.sorted { $0.start < $1.start }
    }

    /// "0:Meeting in "General"" -> "Meeting in "General"". The index moves
    /// when windows open and close; the title is the stable part.
    static func windowName(_ raw: String) -> String {
        guard let colon = raw.firstIndex(of: ":"), raw[..<colon].allSatisfy(\.isNumber) else { return raw }
        return String(raw[raw.index(after: colon)...])
    }

    /// Two apps can show windows with the same title; the app tells them apart.
    static func windowKey(bundleID: String, title: String) -> String {
        bundleID.isEmpty ? title : "\(bundleID)\u{1F}\(title)"
    }

    static func visual(classes: String?, bold: String?, weight: String?, role: String?, value: String?) -> String {
        var parts = [classes ?? "", bold ?? "", weight ?? ""]
        // Level meters and indicator images carry their state in the value.
        if let role, ["AXLevelIndicator", "AXProgressIndicator", "AXValueIndicator"].contains(role) {
            parts.append(value ?? "")
        }
        return parts.joined(separator: "|")
    }
}

// MARK: - Nodes leaving the screen

extension Replay {
    /// A stopped timer alone doesn't end a call (the capture may just have
    /// stopped seeing it). The capture must have run on past the last sign,
    /// and the call must visibly have ended: its window went quiet then
    /// (closed, or replaced by another window), a Leave button went away,
    /// or the app said the meeting ended.
    func callEndConfirmed(after sign: Double) -> Bool {
        guard lastUptime - sign > Self.callEndMargin else { return false }
        if let gone = callSignGoneAt, gone >= sign - Self.callEndMargin { return true }
        if let notice = endedNoticeAt, notice >= sign - Self.callEndMargin { return true }
        let lastSeen = callWindows.compactMap { windowLastSeen[$0] }.max()
        // A window that doesn't change writes nothing between full records
        // (one a minute), so quiet only counts once a full record is missed.
        if let lastSeen, lastSeen <= sign + Self.windowQuietSlack,
           lastUptime - lastSeen > Self.fullRecordGap
        {
            return true
        }
        return false
    }

    /// A call window's last change can trail its last timer tick by this much.
    static let windowQuietSlack = 2.0

    /// Longer than the capture's full-record interval (60 s), so a quiet
    /// window has really gone rather than just not changed.
    static let fullRecordGap = 65.0

    /// A node left the screen: its visual history ends here (so a highlight
    /// can't run on past it), its caption row closes, and a call control
    /// leaving is noted as a sign the call ended.
    mutating func nodeGone(_ key: NodeKey, at time: Double) {
        if let last = visualHistory[key]?.last, last.1 != Self.gone {
            visualHistory[key, default: []].append((time, Self.gone))
        }
        for entry in openLine.keys where entry == key || entry.parent == key || key.parent == entry {
            openLine[entry] = nil
        }
        if callSignNodes.remove(key) != nil {
            callSignGoneAt = max(callSignGoneAt ?? 0, time)
        }
    }

    /// Caption rows already on screen when a snapshot is taken: learn who
    /// each row belongs to, so later text changes are attributed. Not new
    /// speech, so no pings or lines.
    mutating func seedCaptionNames(_ records: [NodeRecord], window: String) {
        for node in records where node.path.hasSuffix(".0") {
            for event in captionEvent(path: node.path, role: node.role, value: node.value, window: window) {
                if let name = event.name { captionNames[event.entry] = name }
            }
        }
    }
}

// MARK: - Windows

extension ParticipantTimelineBuilder {
    /// Teams' chat, activity and calendar windows show
    /// presence and mentions, never who is speaking.
    static func isNonMeetingWindow(_ title: String) -> Bool {
        ["Chat |", "Activity |", "Calendar |", "Teams |", "Files |", "Apps |"].contains { title.hasPrefix($0) }
    }

    /// "Meeting in "General" ended", "Call ended", "You left the meeting".
    static func isEndedNotice(_ text: String) -> Bool {
        let lowered = text.lowercased()
        return lowered.range(of: #"\b(meeting|call)\b.*\bended$|^call ended\b|^you left\b"#, options: .regularExpression) != nil
    }

    /// "31:33" or "1:02:07": a call's running timer.
    static func isCallTimer(_ text: String) -> Bool {
        text.range(of: #"^\d{1,2}(:\d{2}){1,2}$"#, options: .regularExpression) != nil
    }
}

// MARK: - Captions

/// Reading live captions out of the replay.
extension Replay {
    /// Inside (or the root of) a captions panel.
    func isInCaptions(_ key: NodeKey) -> Bool {
        var current: NodeKey? = key
        var steps = 0
        while let candidate = current, steps <= 16 {
            if captionRoots.contains(candidate) { return true }
            current = candidate.parent
            steps += 1
        }
        return false
    }

    /// A caption entry's first child is the speaker's name; a later child
    /// is their words. Only diffs count, so the timing is real.
    func captionEvent(path: String, role: String?, value: String?, window: String) -> [CaptionEvent] {
        guard role == "AXStaticText", let value, !value.isEmpty else { return [] }
        let key = NodeKey(window: window, path: path)
        guard let entry = key.parent, isInCaptions(key) else { return [] }
        if path.hasSuffix(".0") {
            return PersonName.parse(value).map { [CaptionEvent(entry: entry, name: $0, text: nil)] } ?? []
        }
        return [CaptionEvent(entry: entry, name: nil, text: value)]
    }

    /// Teams recycles caption rows: every so often one update rewrites many
    /// old rows at once. Live speech touches one or two rows, so only those
    /// updates count. Each counts as "this person was talking just now".
    mutating func applyCaptions(_ events: [CaptionEvent], at time: Double) {
        guard !events.isEmpty else { return }
        for event in events {
            if let name = event.name { captionNames[event.entry] = name }
        }
        let touched = Set(events.map(\.entry))
        guard touched.count <= 2 else { return }
        let grew = Set(events.filter { $0.name == nil }.map(\.entry))
        for entry in grew {
            if let name = captionNames[entry] {
                captionPings.append((time, name))
            }
        }
        for event in events {
            if let text = event.text, let name = captionNames[event.entry] {
                updateLine(entry: event.entry, name: name, text: text, at: time)
            }
        }
    }

    /// A row's text that still starts the same way is the same caption
    /// growing; anything else is a new caption on a reused row.
    mutating func updateLine(entry: NodeKey, name: String, text: String, at time: Double) {
        guard !text.hasPrefix("[") else { return }
        if let index = openLine[entry], captionLines[index].name == name,
           Self.continues(captionLines[index].text, with: text)
        {
            captionLines[index].text = text
            captionLines[index].end = time
            return
        }
        openLine[entry] = captionLines.count
        captionLines.append(CaptionLine(name: name, text: text, start: time, end: time))
    }

    static func continues(_ old: String, with new: String) -> Bool {
        let oldWords = old.lowercased().split(separator: " ")
        let newWords = new.lowercased().split(separator: " ")
        let count = min(oldWords.count, newWords.count, 2)
        return oldWords.prefix(count).elementsEqual(newWords.prefix(count))
    }

    /// Each caption update covers the speech since the one
    /// before (captions refresh about every 2 s and lag the voice).
    func captionIntervals(timeOffset: Double) -> [SpeakingInterval] {
        captionPings.map { ping in
            SpeakingInterval(
                name: ping.name,
                start: ping.time - Self.captionLead + timeOffset,
                end: ping.time + Self.captionTail + timeOffset
            )
        }
    }
}

// MARK: - Names

public enum PersonName {
    /// Words that show the text is a control or status, not a person.
    static let stopWords: Set<String> = .init([
        "meeting", "chat", "mute", "muted", "unmute", "unmuted", "leave", "share", "camera", "microphone",
        "mic", "context", "menu", "participants", "participant", "people", "general", "teams", "zoom",
        "invite", "copy", "close", "profile", "start", "navigate", "add", "more", "raise", "hand", "video",
        "audio", "join", "view", "gallery", "speaker", "record", "recording", "settings", "window", "web",
        "content", "call", "available", "busy", "away", "offline", "reply", "replies", "channel", "channels",
        "the", "and", "with", "your", "you", "is", "in", "of", "to", "for", "now", "off", "on", "new",
        "search", "calendar", "activity", "files", "apps", "help", "reactions", "react", "show", "hide",
        "turn", "stop", "end", "options", "toolbar", "button", "tab", "panel", "pane", "list", "item",
        "live", "caption", "captions", "transcript", "mentioned", "lobby", "waiting", "external", "unfamiliar", "doing", "ok"
    ]).union(deviceWords).union(replyWords)

    /// Audio devices the meeting app lists ("MacBook Pro Speakers").
    static let deviceWords: Set<String> = [
        "airpods", "beats", "speakers", "headphones", "headset", "earbuds", "earphones", "macbook", "imac",
        "iphone", "ipad", "airplay", "bluetooth", "usb", "default", "built-in", "display", "monitor", "webcam"
    ]

    /// Short replies that look like names when capitalized ("Yes, Sir.").
    static let replyWords: Set<String> = [
        "yes", "no", "yeah", "yep", "nope", "sir", "hey", "hi", "hello", "thanks", "thank", "okay", "sure", "bye"
    ]

    /// Text that is clearly not a person: a device, a short
    /// reply, or a possessive ("Sam's AirPods Pro"). Used to clean up people
    /// an earlier build created from such text.
    public static func isNotAPerson(_ text: String) -> Bool {
        let words = stripTags(text).replacingOccurrences(of: ",", with: " ").split(separator: " ").map { $0.lowercased() }
        return words.contains { word in
            let bare = word.trimmingCharacters(in: .punctuationCharacters)
            return deviceWords.contains(bare) || replyWords.contains(bare) || isPossessive(bare)
        }
    }

    static func isPossessive(_ word: String) -> Bool {
        word.hasSuffix("'s") || word.hasSuffix("\u{2019}s")
    }

    static let statusTokens: Set<String> = ["muted", "unmuted", "context menu is available", "presenting", "speaking"]

    /// The person's name in an accessibility label, or nil.
    /// "Nora Hale, Context menu is available" -> "Nora Hale"
    /// "Brooks, Daniel, muted" -> "Brooks, Daniel"
    public static func parse(_ text: String) -> String? {
        let parts = text.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
        guard let first = parts.first.map(stripTags) else { return nil }
        if isName(first, minWords: 2) {
            return first
        }
        // "Last, First" as Teams shows some directory names.
        if parts.count >= 2, isName(first, minWords: 1), first.split(separator: " ").count == 1 {
            let second = stripTags(parts[1])
            if !statusTokens.contains(second.lowercased()), isName(second, minWords: 1), second.split(separator: " ").count <= 2 {
                return "\(first), \(second)"
            }
        }
        return nil
    }

    /// "Carter, Sam" and "Sam Carter" are the same person.
    public static func same(_ lhs: String, _ rhs: String) -> Bool {
        func key(_ name: String) -> String {
            let parts = name.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
            let ordered = parts.count == 2 ? "\(parts[1]) \(parts[0])" : name
            return ordered.lowercased().split(separator: " ").joined(separator: " ")
        }
        return key(lhs) == key(rhs)
    }

    public static func isMuted(_ text: String) -> Bool {
        text.split(separator: ",").contains { $0.trimmingCharacters(in: .whitespaces).lowercased() == "muted" }
    }

    /// Drops any "(…)" tag: "(Guest)", "(External)", and organisation tags
    /// like "Lopez, Maria (AGENCY)".
    static func stripTags(_ text: String) -> String {
        text.replacingOccurrences(of: #"\s*\([^)]*\)"#, with: "", options: .regularExpression)
            .trimmingCharacters(in: .whitespaces)
    }

    static func isName(_ text: String, minWords: Int) -> Bool {
        guard text.count <= 40 else { return false }
        let words = text.split(separator: " ")
        guard words.count >= minWords, words.count <= 4 else { return false }
        for word in words {
            guard let first = word.first, first.isUppercase, first.isLetter else { return false }
            guard word.allSatisfy({ $0.isLetter || $0 == "'" || $0 == "-" || $0 == "." || $0 == "\u{2019}" }) else { return false }
            let lowered = word.lowercased()
            if stopWords.contains(lowered.trimmingCharacters(in: .punctuationCharacters)) || isPossessive(lowered) {
                return false
            }
        }
        return true
    }
}
