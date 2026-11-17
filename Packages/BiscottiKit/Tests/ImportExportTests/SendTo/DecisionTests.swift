import DataStore
import Foundation
import Testing
@testable import ImportExport

@Suite("SendDecision")
struct DecisionTests {
    private let fixedDate = Date(timeIntervalSince1970: 1_792_778_400)

    // MARK: - No record

    @Test("No record returns .send")
    func noRecord() {
        let result = SendDecision.decide([], for: .obsidian, currentHash: "abc")
        #expect(result == .send)
    }

    // MARK: - Same hash

    @Test("Same hash returns alreadySent with changed: false")
    func sameHash() {
        let records = [SentExport(destination: .obsidian, contentHash: "abc", sentAt: fixedDate)]
        let result = SendDecision.decide(records, for: .obsidian, currentHash: "abc")
        #expect(result == .alreadySent(sentAt: fixedDate, changed: false))
    }

    // MARK: - Different hash

    @Test("Different hash returns alreadySent with changed: true")
    func differentHash() {
        let records = [SentExport(destination: .obsidian, contentHash: "abc", sentAt: fixedDate)]
        let result = SendDecision.decide(records, for: .obsidian, currentHash: "xyz")
        #expect(result == .alreadySent(sentAt: fixedDate, changed: true))
    }

    // MARK: - Other destination ignored

    @Test("Record for another destination is ignored")
    func otherDestination() {
        let records = [SentExport(destination: .bear, contentHash: "abc", sentAt: fixedDate)]
        let result = SendDecision.decide(records, for: .obsidian, currentHash: "abc")
        #expect(result == .send)
    }

    // MARK: - Multiple records

    @Test("Multiple records: only the matching destination matters")
    func multipleRecords() {
        let records = [
            SentExport(destination: .bear, contentHash: "xyz", sentAt: fixedDate),
            SentExport(destination: .obsidian, contentHash: "abc", sentAt: fixedDate)
        ]
        let result = SendDecision.decide(records, for: .obsidian, currentHash: "abc")
        #expect(result == .alreadySent(sentAt: fixedDate, changed: false))
    }
}
