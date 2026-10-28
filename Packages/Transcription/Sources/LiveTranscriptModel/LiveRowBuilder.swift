import Foundation

/// Builds one track's rows from settled words and a tail, the same way for
/// every live engine.
///
/// A row closes, and the next word opens a new one:
/// - after a pause of `rowPause`;
/// - at a sentence end once the row is `sentenceRowLength` long;
/// - at a word boundary once it is `maxRowLength` long;
/// - before a word at or after a break inside the row (`breakRow(at:)`): the
///   other track started speaking there, so this side's next words follow
///   that side's row, and rows in start-time order read like a conversation.
///
/// The tail splits by the same rules: the words the open row would take show
/// in it, the rest on a row of their own, whose ID the next new row takes, so
/// a bubble keeps its identity when its tail settles.
///
/// `settle` invalidates the tail; callers set it again afterward.
package struct LiveRowBuilder {
    package static let rowPause: TimeInterval = 1.5
    /// A row this long closes at its next sentence end.
    package static let sentenceRowLength: TimeInterval = 8
    /// A row this long closes at its next word.
    package static let maxRowLength: TimeInterval = 20

    package let track: LiveTrack
    /// The words that may still change.
    package private(set) var tail: [TimedWord] = []
    /// Where this track last started speaking: the start of the newest word,
    /// settled or in the tail, that follows a pause of `rowPause`, or of the
    /// track's first word. A row split by length or by a break is not new
    /// speech, so two tracks never keep splitting each other's rows.
    package private(set) var latestSpeechStart: TimeInterval?
    /// The row receiving settled words. It always has settled text.
    private var openRow: OpenRow?
    /// Shows the tail words the open row does not take. Kept after its tail
    /// moves away, so its ID goes to the next new row.
    private var tailRow: LiveRow?
    /// How many of the tail's first words show in the open row.
    private var tailWordsInOpenRow = 0
    /// Times the other track started speaking inside the open or next row.
    private var breaks: [TimeInterval] = []
    /// The end of the newest settled word.
    private var settledEnd: TimeInterval?
    /// Rows closed since the last `takeChanges(since:)`.
    private var closed: [LiveRow] = []

    package init(track: LiveTrack) {
        self.track = track
    }

    /// The rows that can still change: the open row, with the tail words it
    /// takes, and the tail's own row.
    package var currentRows: [LiveRow] {
        var rows: [LiveRow] = []
        if let row = openRow {
            rows.append(row.liveRow(track: track, tail: tail.prefix(tailWordsInOpenRow)))
        }
        if let tailRow {
            rows.append(tailRow)
        }
        return rows
    }

    /// Appends settled words in time order, closing the open row first where
    /// the rules say. Clears the tail: the caller sets the new one.
    /// - Parameter forced: Marks the rows that receive the words as a forced boundary.
    package mutating func settle(_ words: some Collection<TimedWord>, forced: Bool = false) {
        for word in words {
            if let row = openRow, row.closes(before: word, breaks: breaks) {
                closed.append(row.closedRow(track: track))
                openRow = nil
            }
            if var row = openRow {
                row.append(word)
                openRow = row
            } else {
                noteSpeech(at: word, after: settledEnd)
                breaks.removeAll { $0 <= word.start }
                openRow = OpenRow(id: tailRow?.id ?? UUID(), first: word)
                tailRow = nil
            }
            if forced {
                openRow?.isForcedBoundary = true
            }
            settledEnd = max(settledEnd ?? word.end, word.end)
        }
        tail = []
        tailWordsInOpenRow = 0
    }

    /// Replaces the tail.
    package mutating func setTail(_ words: [TimedWord]) {
        tail = words
        placeTail()
    }

    /// Closes the open row; the next settled word starts a new one.
    package mutating func closeOpenRow() {
        if let row = openRow {
            closed.append(row.closedRow(track: track))
            openRow = nil
        }
        breaks = []
        placeTail()
    }

    /// The other track started speaking at `time`. A row that began before
    /// it, open, still all tail or not decoded yet, takes no word from `time`
    /// on. A row that began after it needs no break.
    package mutating func breakRow(at time: TimeInterval) {
        let rowStart = openRow?.startTime ?? tailRow.flatMap { $0.hasText ? $0.startTime : nil }
        if let rowStart, rowStart >= time { return }
        guard !breaks.contains(time) else { return }
        // A new row drops the breaks before it; while this track is silent,
        // only the newest can still fall inside its next row.
        breaks = Array((breaks + [time]).suffix(Self.keptBreaks))
        placeTail()
    }

    private static let keptBreaks = 8

    /// The rows closed since the last call, plus the current rows that differ
    /// from `before`, in time order.
    package mutating func takeChanges(since before: [LiveRow]) -> [LiveRow] {
        defer { closed = [] }
        return (closed + currentRows.filter { !before.contains($0) }).sorted { $0.startTime < $1.startTime }
    }

    /// Words joined verbatim; a row's first word loses its separating space.
    package static func rowText(_ words: some Collection<TimedWord>, startsRow: Bool) -> String {
        let text = words.map(\.text).joined()
        return startsRow ? String(text.drop { $0.isWhitespace }) : text
    }

    /// Splits the tail between the open row and the tail's own row by the
    /// rules `settle` applies, so a tail word settles into the row that shows it.
    private mutating func placeTail() {
        tailWordsInOpenRow = 0
        if var row = openRow {
            for word in tail {
                guard !row.closes(before: word, breaks: breaks) else { break }
                row.append(word)
                tailWordsInOpenRow += 1
            }
        }
        let rest = tail.dropFirst(tailWordsInOpenRow)
        guard let first = rest.first, let last = rest.last else {
            tailRow?.tailText = ""
            return
        }
        let previousEnd = tailWordsInOpenRow > 0 ? tail[tailWordsInOpenRow - 1].end : settledEnd
        noteSpeech(at: first, after: previousEnd)
        var row = tailRow ?? LiveRow(track: track, startTime: first.start, endTime: last.end)
        row.startTime = first.start
        row.endTime = last.end
        row.tailText = Self.rowText(rest, startsRow: true)
        tailRow = row
    }

    /// Records `word` as new speech when a pause precedes it.
    private mutating func noteSpeech(at word: TimedWord, after previousEnd: TimeInterval?) {
        guard previousEnd.map({ word.start - $0 >= Self.rowPause }) ?? true else { return }
        latestSpeechStart = max(latestSpeechStart ?? word.start, word.start)
    }
}

extension LiveRowBuilder {
    private struct OpenRow {
        let id: UUID
        let startTime: TimeInterval
        var settledText: String
        var settledEnd: TimeInterval
        var endsSentence: Bool
        var isForcedBoundary = false

        init(id: UUID, first word: TimedWord) {
            self.id = id
            startTime = word.start
            settledText = LiveRowBuilder.rowText([word], startsRow: true)
            settledEnd = word.end
            endsSentence = word.endsSentence
        }

        mutating func append(_ word: TimedWord) {
            settledText += LiveRowBuilder.rowText([word], startsRow: settledText.isEmpty)
            settledEnd = max(settledEnd, word.end)
            endsSentence = word.endsSentence
        }

        /// Whether `word` starts a new row instead of joining this one.
        func closes(before word: TimedWord, breaks: [TimeInterval]) -> Bool {
            if word.start - settledEnd >= LiveRowBuilder.rowPause { return true }
            let length = settledEnd - startTime
            if length >= LiveRowBuilder.maxRowLength { return true }
            if length >= LiveRowBuilder.sentenceRowLength, endsSentence { return true }
            return breaks.contains { $0 > startTime && word.start >= $0 }
        }

        func liveRow(track: LiveTrack, tail: some Collection<TimedWord>) -> LiveRow {
            LiveRow(
                id: id,
                track: track,
                startTime: startTime,
                endTime: max(settledEnd, tail.map(\.end).max() ?? settledEnd),
                settledText: settledText,
                tailText: LiveRowBuilder.rowText(tail, startsRow: settledText.isEmpty),
                isForcedBoundary: isForcedBoundary
            )
        }

        func closedRow(track: LiveTrack) -> LiveRow {
            var row = liveRow(track: track, tail: [])
            row.isClosed = true
            return row
        }
    }
}
