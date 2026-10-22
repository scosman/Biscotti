import Foundation
import STTLabCore
@testable import STTLabHome
import Testing

// MARK: - Helpers

/// Build a CandidateMeeting with compact defaults.
private func candidate(
    uuid: UUID = UUID(),
    title: String = "Meeting",
    date: Date = Date(timeIntervalSinceReferenceDate: 0),
    durationMinutes: Double = 30,
    speakerCount: Int = 3,
    wordCount: Int = 3000,
    language: String = "en"
) -> CandidateMeeting {
    CandidateMeeting(
        meetingUUID: uuid,
        title: title,
        date: date,
        durationSeconds: durationMinutes * 60,
        micPath: "/mic.aac",
        systemPath: "/system.aac",
        speakerCount: speakerCount,
        wordCount: wordCount,
        language: language
    )
}

/// Fixed UUIDs for deterministic tests.
private let uuids = (0 ..< 20).map { i in
    UUID(uuidString: String(format: "00000000-0000-0000-0000-%012d", i))!
}

// MARK: - Tests

@Suite("Selector")
struct SelectionTests {
    @Test("Fills both buckets when enough candidates exist")
    func fillsBothBuckets() {
        // 5 short (30 min) + 5 long (60 min) candidates.
        var candidates: [CandidateMeeting] = []
        for i in 0 ..< 5 {
            candidates.append(candidate(
                uuid: uuids[i],
                title: "Short \(i)",
                date: Date(timeIntervalSinceReferenceDate: Double(i) * 86400),
                durationMinutes: 30,
                speakerCount: 2 + (i % 3),
                wordCount: 2000 + i * 200
            ))
        }
        for i in 0 ..< 5 {
            candidates.append(candidate(
                uuid: uuids[5 + i],
                title: "Long \(i)",
                date: Date(timeIntervalSinceReferenceDate: Double(5 + i) * 86400),
                durationMinutes: 60,
                speakerCount: 3 + (i % 2),
                wordCount: 5000 + i * 300
            ))
        }

        let selection = Selector.propose(candidates, short: 5, long: 5)

        // All 10 are selected (5 + 5).
        #expect(selection.meetings.count == 10)

        let shortCount = selection.meetings.filter { $0.bucket == .short }.count
        let longCount = selection.meetings.filter { $0.bucket == .long }.count
        #expect(shortCount == 5)
        #expect(longCount == 5)

        // No shortfall notes.
        #expect(selection.notes.isEmpty)
    }

    @Test("Shortfall fill when a bucket has too few candidates")
    func shortfallFill() {
        // Only 2 short candidates, 5 long candidates.
        var candidates: [CandidateMeeting] = []
        for i in 0 ..< 2 {
            candidates.append(candidate(
                uuid: uuids[i],
                title: "Short \(i)",
                durationMinutes: 30,
                speakerCount: 3,
                wordCount: 2000 + i * 200
            ))
        }
        for i in 0 ..< 5 {
            candidates.append(candidate(
                uuid: uuids[2 + i],
                title: "Long \(i)",
                durationMinutes: 60,
                speakerCount: 3,
                wordCount: 5000 + i * 300
            ))
        }
        // Add some medium-duration candidates for shortfall fills.
        for i in 0 ..< 5 {
            candidates.append(candidate(
                uuid: uuids[7 + i],
                title: "Medium \(i)",
                durationMinutes: 45,
                speakerCount: 3,
                wordCount: 3000 + i * 100
            ))
        }

        let selection = Selector.propose(candidates, short: 5, long: 5)

        // Should still have 10 total (2 short + 3 fill + 5 long).
        #expect(selection.meetings.count == 10)

        let shortBucket = selection.meetings.filter { $0.bucket == .short }.count
        #expect(shortBucket == 2)

        // The shortfall fill has bucket == nil.
        let fills = selection.meetings.filter { $0.bucket == nil }.count
        #expect(fills == 3)

        // Should have a note about the shortfall.
        #expect(selection.notes.contains(where: { $0.contains("short bucket") }))
    }

    @Test("Total fewer than requested adds a note")
    func fewerThanRequested() {
        let a = candidate(uuid: uuids[0], title: "A", durationMinutes: 30)
        let b = candidate(uuid: uuids[1], title: "B", durationMinutes: 60)

        let selection = Selector.propose([a, b], short: 5, long: 5)

        #expect(selection.meetings.count == 2)
        #expect(selection.notes.contains(where: { $0.contains("only 2 eligible") }))
    }

    @Test("Non-English language adds a locale note")
    func nonEnglishLocaleNote() {
        let c = candidate(uuid: uuids[0], title: "German call", durationMinutes: 30, language: "de")

        let selection = Selector.propose([c], short: 5, long: 5)

        #expect(selection.meetings.count == 1)
        #expect(selection.notes.contains(where: { $0.contains("language is de") }))
    }

    @Test("Alternates are populated from remaining candidates")
    func alternatesPopulated() {
        // 15 short candidates — only 5 fit, 10 remain.
        var candidates: [CandidateMeeting] = []
        for i in 0 ..< 15 {
            candidates.append(candidate(
                uuid: uuids[i],
                title: "M\(i)",
                date: Date(timeIntervalSinceReferenceDate: Double(i) * 86400),
                durationMinutes: 30 + Double(i % 3),
                speakerCount: 2 + (i % 4),
                wordCount: 2000 + i * 100
            ))
        }

        let selection = Selector.propose(candidates, short: 5, long: 0)

        #expect(selection.meetings.count == 5)
        #expect(selection.alternates.count == 10)

        // Alternates do not overlap with chosen.
        let chosenUUIDs: Set<UUID> = Set(selection.meetings.map { $0.meetingUUID })
        let altUUIDs: Set<UUID> = Set(selection.alternates.map { $0.meetingUUID })
        #expect(chosenUUIDs.isDisjoint(with: altUUIDs))
    }

    @Test("Ordering: short first, then long, then fills, then by date")
    func ordering() {
        let longC = candidate(
            uuid: uuids[0], title: "Long",
            date: Date(timeIntervalSinceReferenceDate: 0),
            durationMinutes: 60
        )
        let shortC = candidate(
            uuid: uuids[1], title: "Short",
            date: Date(timeIntervalSinceReferenceDate: 86400),
            durationMinutes: 30
        )

        let selection = Selector.propose([longC, shortC], short: 1, long: 1)

        #expect(selection.meetings.count == 2)
        #expect(selection.meetings[0].bucket == .short)
        #expect(selection.meetings[1].bucket == .long)
    }

    @Test("Deterministic: same input always produces same output")
    func deterministic() {
        var candidates: [CandidateMeeting] = []
        for i in 0 ..< 10 {
            let dur: Double = i < 5 ? 30 : 60
            candidates.append(candidate(
                uuid: uuids[i],
                title: "M\(i)",
                date: Date(timeIntervalSinceReferenceDate: Double(i) * 86400),
                durationMinutes: dur,
                speakerCount: 2 + (i % 3),
                wordCount: 2000 + i * 300
            ))
        }

        let a = Selector.propose(candidates, short: 3, long: 3)
        let b = Selector.propose(candidates, short: 3, long: 3)

        let aUUIDs: [UUID] = a.meetings.map { $0.meetingUUID }
        let bUUIDs: [UUID] = b.meetings.map { $0.meetingUUID }
        #expect(aUUIDs == bUUIDs)
    }

    @Test("Default appleLocale is en_US")
    func defaultLocale() {
        let selection = Selector.propose(
            [candidate(uuid: uuids[0])],
            short: 1, long: 0
        )
        #expect(selection.meetings.first?.appleLocale == "en_US")
    }

    @Test("wordsPerMinute computed correctly")
    func wordsPerMinute() {
        let c = candidate(durationMinutes: 30, wordCount: 3000)
        #expect(c.wordsPerMinute == 100.0)
    }

    @Test("Empty candidates returns empty selection")
    func emptyCandidates() {
        let selection = Selector.propose([], short: 5, long: 5)
        #expect(selection.meetings.isEmpty)
        #expect(selection.alternates.isEmpty)
        #expect(selection.notes.contains(where: { $0.contains("only 0 eligible") }))
    }
}
