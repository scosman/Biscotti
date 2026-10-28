import Foundation
import Observation

/// One find match: a range in a bubble's ``Bubble/fullText``.
public struct FindMatch: Equatable, Sendable {
    public var itemID: String
    public var range: Range<String.Index>
}

/// The find highlights of one bubble.
public struct BubbleHighlights: Equatable, Sendable {
    public static let none = BubbleHighlights(ranges: [], currentIndex: nil)

    /// Ranges in the bubble's ``Bubble/fullText``.
    public var ranges: [Range<String.Index>]
    /// The index in `ranges` of the current match, if it is in this bubble.
    public var currentIndex: Int?
}

/// Find in the transcript: the query, its matches and the current match.
/// Case- and diacritic-insensitive.
@MainActor @Observable
public final class FindState {
    public var isOpen = false
    public var query = "" {
        didSet {
            guard query != oldValue else { return }
            recompute(keepingCurrent: false)
        }
    }

    public private(set) var matches: [FindMatch] = []
    public private(set) var currentIndex: Int?

    @ObservationIgnored private var items: [TranscriptItem] = []

    public init() {}

    /// "2 of 5"; "Not found" when nothing matches; nil with an empty query.
    public var countText: String? {
        guard !query.isEmpty else { return nil }
        guard let currentIndex else { return "Not found" }
        return "\(currentIndex + 1) of \(matches.count)"
    }

    public var currentMatch: FindMatch? {
        currentIndex.map { matches[$0] }
    }

    /// Searches these items from now on. The current match stays current
    /// when it still exists.
    public func update(items: [TranscriptItem]) {
        self.items = items
        recompute(keepingCurrent: true)
    }

    public func next() {
        guard let currentIndex, !matches.isEmpty else { return }
        self.currentIndex = (currentIndex + 1) % matches.count
    }

    public func previous() {
        guard let currentIndex, !matches.isEmpty else { return }
        self.currentIndex = (currentIndex - 1 + matches.count) % matches.count
    }

    /// Closes find and clears the query and every highlight.
    public func close() {
        isOpen = false
        query = ""
        matches = []
        currentIndex = nil
    }

    public func highlights(for itemID: String) -> BubbleHighlights {
        guard !matches.isEmpty else { return .none }
        var ranges: [Range<String.Index>] = []
        var current: Int?
        for (index, match) in matches.enumerated() where match.itemID == itemID {
            if index == currentIndex { current = ranges.count }
            ranges.append(match.range)
        }
        return ranges.isEmpty ? .none : BubbleHighlights(ranges: ranges, currentIndex: current)
    }

    private func recompute(keepingCurrent: Bool) {
        let previous = keepingCurrent ? currentMatch : nil
        matches = query.isEmpty ? [] : items.flatMap { item in
            Self.ranges(of: query, in: item.bubble?.fullText ?? "").map {
                FindMatch(itemID: item.id, range: $0)
            }
        }
        if matches.isEmpty {
            currentIndex = nil
        } else if let previous, let kept = matches.firstIndex(of: previous) {
            currentIndex = kept
        } else {
            currentIndex = 0
        }
    }

    private static func ranges(of query: String, in text: String) -> [Range<String.Index>] {
        var found: [Range<String.Index>] = []
        var searchStart = text.startIndex
        while searchStart < text.endIndex,
              let range = text.range(
                  of: query,
                  options: [.caseInsensitive, .diacriticInsensitive],
                  range: searchStart ..< text.endIndex
              )
        {
            found.append(range)
            searchStart = range.upperBound
        }
        return found
    }
}
