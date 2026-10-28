import Foundation
import Testing
@testable import TranscriptUI

private func textItem(_ id: String, settled: String, tail: String = "") -> TranscriptItem {
    TranscriptItem(
        id: id,
        kind: .bubble(Bubble(side: .leading, startTime: 0, endTime: 1, settledText: settled, tailText: tail))
    )
}

@Suite("FindState")
@MainActor
struct FindStateTests {
    private let items = [
        textItem("a", settled: "The Café opens at nine."),
        textItem("b", settled: "Cafe or tea?", tail: " CAFÉ again"),
        TranscriptItem(id: "gap-1000", kind: .gap(startTime: 1, duration: 2, cause: .notTranscribedLive)),
        textItem("c", settled: "Nothing here.")
    ]

    private func matchedText(_ match: FindMatch) -> String {
        let bubble = items.first { $0.id == match.itemID }?.bubble
        return String(bubble?.fullText[match.range] ?? "")
    }

    @Test("finds matches ignoring case and diacritics, in settled text and tails")
    func findsMatchesCaseAndDiacriticInsensitive() {
        let find = FindState()
        find.update(items: items)

        find.query = "cafe"

        #expect(find.matches.map(\.itemID) == ["a", "b", "b"])
        #expect(find.matches.map(matchedText) == ["Café", "Cafe", "CAFÉ"])
        #expect(find.currentIndex == 0)
        #expect(find.highlights(for: "b") == BubbleHighlights(ranges: [find.matches[1].range, find.matches[2].range], currentIndex: nil))
        #expect(find.highlights(for: "a").currentIndex == 0)
        #expect(find.highlights(for: "c") == .none)
    }

    @Test("next and previous wrap around")
    func nextWrapsAround() {
        let find = FindState()
        find.update(items: items)
        find.query = "cafe"

        find.next()
        find.next()
        #expect(find.currentIndex == 2)
        find.next()
        #expect(find.currentIndex == 0)
        find.previous()
        #expect(find.currentIndex == 2)
    }

    @Test("the count reads n of m")
    func countFormatsAsOneOfN() {
        let find = FindState()
        find.update(items: items)
        #expect(find.countText == nil)

        find.query = "cafe"
        find.next()
        #expect(find.countText == "2 of 3")

        find.query = "zebra"
        #expect(find.countText == "Not found")
    }

    @Test("close clears the query, the matches and every highlight")
    func closeClearsHighlights() {
        let find = FindState()
        find.isOpen = true
        find.update(items: items)
        find.query = "cafe"

        find.close()

        #expect(!find.isOpen)
        #expect(find.query.isEmpty)
        #expect(find.matches.isEmpty)
        #expect(find.currentIndex == nil)
        #expect(find.highlights(for: "a") == .none)
    }

    @Test("new items keep the current match when it still exists")
    func updateKeepsCurrentMatchWhenItStillExists() {
        let find = FindState()
        find.update(items: items)
        find.query = "cafe"
        find.next()
        let current = find.currentMatch

        find.update(items: [textItem("z", settled: "cafe first")] + items)

        #expect(find.matches.count == 4)
        #expect(find.currentMatch == current)
        #expect(find.currentIndex == 2)
    }
}
