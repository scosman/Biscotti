import Foundation
import SQLite3
import Testing
import Transcription
@testable import DataStore

// MARK: - Schema Assertion (gating — runs in `make test`)

/// Guards against silent breakage when Core Data schema changes break the
/// transcript SQL search. Verifies that the FK naming rule
/// (`Z` + parent's `Z_ENT` + relationship name) produces column names that
/// actually exist in the store. If entity numbers shift after a model change,
/// this test still passes (it derives them); if a migration breaks the
/// schema shape, it fails CI.
@Suite("Core Data schema resolution")
struct SchemaAssertionTests {
    @Test("Derived FK columns exist on a fresh store")
    func schemaResolution() async throws {
        let dir = makeTempDir()
        defer { cleanupDir(dir) }

        // Create a minimal store and save at least one row per table
        // so Core Data writes the schema.
        let store = try DataStore(storage: .onDisk(dir))
        let meetingID = try await store.createMeeting(title: "Schema Check")
        let seg = TranscriptSegment(
            speakerID: 0, speakerLabel: "S0",
            startTime: 0, endTime: 1,
            text: "hello",
            confidence: 0.9, noSpeechProbability: 0.1, words: nil
        )
        let txResult = TranscriptResult(
            transcriptionMethodId: "test", language: "en", speakerCount: 1,
            segments: [seg], speakerEmbeddings: [:], processingDuration: 0.1
        )
        let txID = try await store.addTranscript(
            txResult, vocabularyUsed: [], mappedEventIdentifier: nil, to: meetingID
        )
        try await store.setPreferredTranscript(txID, for: meetingID)

        // Open the file read-only and inspect the schema.
        let dbPath = dir.appending(path: "Biscotti.store").path
        let database = try TestReadOnlyDB(path: dbPath)

        // Read Z_PRIMARYKEY to get entity numbers.
        let registry = try database.entityRegistry()

        // Our three entities must exist and must not use inheritance.
        let meetingEnt = try #require(registry["Meeting"], "Meeting entity must exist")
        let transcriptEnt = try #require(registry["TranscriptRecord"], "TranscriptRecord entity must exist")
        let segmentEnt = try #require(registry["TranscriptSegmentRecord"], "entity must exist")
        #expect(meetingEnt.superEntity == 0, "Meeting must not use inheritance")
        #expect(transcriptEnt.superEntity == 0, "TranscriptRecord must not use inheritance")
        #expect(segmentEnt.superEntity == 0, "TranscriptSegmentRecord must not use inheritance")

        // Derive FK names using the same rule as ResolvedSearchSchema.
        let expectedSegFK = "Z\(transcriptEnt.entityNumber)SEGMENTS"
        let expectedTxFK = "Z\(meetingEnt.entityNumber)TRANSCRIPTS"

        // Verify derived FK columns exist in the store.
        let segCols = try database.columnNames(table: "ZTRANSCRIPTSEGMENTRECORD")
        #expect(segCols.contains(expectedSegFK),
                "Segment FK '\(expectedSegFK)' must exist on ZTRANSCRIPTSEGMENTRECORD")
        #expect(segCols.contains("ZTEXT"), "Segment table must have ZTEXT")

        let txCols = try database.columnNames(table: "ZTRANSCRIPTRECORD")
        #expect(txCols.contains(expectedTxFK),
                "Transcript FK '\(expectedTxFK)' must exist on ZTRANSCRIPTRECORD")
        #expect(txCols.contains("ZID"), "Transcript table must have ZID")

        // Non-FK columns that the search query also depends on.
        let meetingCols = try database.columnNames(table: "ZMEETING")
        #expect(meetingCols.contains("ZID"), "Meeting table must have ZID")
        #expect(meetingCols.contains("ZPREFERREDTRANSCRIPTID"), "Meeting table must have ZPREFERREDTRANSCRIPTID")
        #expect(meetingCols.contains("ZSUMMARY"), "Meeting table must have ZSUMMARY")
        #expect(meetingCols.contains("ZNOTES"), "Meeting table must have ZNOTES")

        // Date columns used by meetingDateProjections() for sort+truncate.
        #expect(meetingCols.contains("ZSTARTDATE"), "Meeting table must have ZSTARTDATE")
        #expect(meetingCols.contains("ZCREATEDAT"), "Meeting table must have ZCREATEDAT")
    }
}

// MARK: - Date Projection Precision (gating — runs in `make test`)

/// Verifies that SQL-projected dates (Core Data's `Double` seconds since
/// reference date) sort identically to SwiftData's `Date` values.
/// The projected path uses these dates to sort+truncate before fetching full
/// rows; a precision mismatch would silently return the wrong top-N.
@Suite("Date projection precision")
struct DateProjectionPrecisionTests {
    @Test("SQL-projected dates produce the same sort order as SwiftData dates")
    func dateSortOrderMatches() async throws {
        let dir = makeTempDir()
        defer { cleanupDir(dir) }

        let store = try DataStore(storage: .onDisk(dir))

        // Create meetings with dates spanning sub-second precision.
        let baseDate = Date(timeIntervalSinceReferenceDate: 800_000_000)
        let meetingCount = 20
        var expectedOrder: [(id: UUID, date: Date)] = []
        for idx in 0 ..< meetingCount {
            // Vary by fractional seconds to test precision.
            let offset = Double(idx) * 0.123_456_789
            let startDate = baseDate.addingTimeInterval(offset)
            let meetingID = try await store.createMeeting(
                title: "Date test \(idx)", start: startDate
            )
            expectedOrder.append((id: meetingID, date: startDate))
        }

        // SwiftData order: sort by startDate descending.
        let swiftDataOrder = try await store.read { dataStore in
            let all = try dataStore.fetchAllMeetings()
            return all
                .sorted { ($0.startDate ?? $0.createdAt) > ($1.startDate ?? $1.createdAt) }
                .map(\.id)
        }

        // SQL projection order: sort by effectiveDate descending.
        let dbPath = dir.appending(path: "Biscotti.store").path
        let database = try TestReadOnlyDB(path: dbPath)
        let projections = try database.meetingDateProjections()

        var sqlOrder = projections.map { (id: $0.key, date: $0.value.effectiveDate) }
        sqlOrder.sort { $0.date > $1.date }
        let sqlIDs = sqlOrder.map(\.id)

        #expect(
            swiftDataOrder == sqlIDs,
            "SQL-projected date sort must match SwiftData date sort"
        )

        // Verify sub-second precision is preserved.
        for (id, date) in expectedOrder {
            guard let proj = projections[id] else {
                Issue.record("Missing projection for meeting \(id)")
                continue
            }
            let diff = abs(proj.effectiveDate.timeIntervalSince(date))
            #expect(diff < 0.000_001, "Date precision lost for meeting \(id): diff=\(diff)s")
        }
    }
}

// MARK: - Differential Test (gating — runs in `make test`)

/// Compares the new hybrid search against the original full-fetch oracle.
/// Generated data has no summaries, so both paths should produce identical
/// results (the oracle does not search the `.summary` field).
@Suite("Search differential: hybrid vs oracle")
struct SearchDifferentialTests {
    @Test("Hybrid search matches oracle on generated data")
    func hybridMatchesOracle() async throws {
        let dir = makeTempDir()
        defer { cleanupDir(dir) }

        let store = try DataStore(storage: .onDisk(dir))
        try await populateDifferentialData(store: store)

        let queries = ["xyzorphan", "meeting", "alice", "important", "budget", "meeting alice"]
        for query in queries {
            try await assertHybridMatchesOracle(store: store, query: query)
        }
    }
}

/// Populates a store with varied data (meetings, people, tags, notes, transcripts)
/// for the differential test.
private func populateDifferentialData(store: DataStore) async throws {
    let rareToken = "xyzorphan"
    var rng = TestLCG(seed: 42)
    for idx in 0 ..< 10 {
        let title = "Meeting \(idx) \(testWords[Int(rng.next() % UInt64(testWords.count))])"
        let segTexts = (0 ..< 5).map { _ in testSegmentText(rng: &rng, count: 20) }
        var segs = segTexts
        if idx == 2 || idx == 7, !segs.isEmpty {
            segs[0] = rareToken + " " + segs[0]
        }
        try await store.bulkInsertMeetingsWithTranscripts(titles: [title], segmentTexts: [segs])
    }

    let meetingIDs = try await store.read { store in
        try store.fetchAllMeetings().map(\.id)
    }
    let aliceID = try await store.findOrCreatePerson(name: "Alice Wonderland", email: nil)
    try await store.setParticipants([aliceID], organizer: nil, for: meetingIDs[0])
    _ = try await store.createTagAndApply(name: "Important", to: meetingIDs[1])
    try await store.setNotes("budget allocation notes", for: meetingIDs[3])
}

/// Asserts that hybrid `searchHits` and the oracle produce the same IDs and scores.
private func assertHybridMatchesOracle(store: DataStore, query: String) async throws {
    let hybrid = try await store.read { try $0.searchHits(query, limit: 100) }
    let oracle = try await store.read { try $0.searchHitsOracle(query, limit: 100) }

    let hybridIDs = Set(hybrid.map(\.id))
    let oracleIDs = Set(oracle.map(\.id))
    #expect(
        hybridIDs == oracleIDs,
        "Meeting IDs differ for query \"\(query)\": hybrid=\(hybridIDs.count) oracle=\(oracleIDs.count)"
    )

    let hybridScores = Dictionary(uniqueKeysWithValues: hybrid.map { ($0.id, $0.score) })
    let oracleScores = Dictionary(uniqueKeysWithValues: oracle.map { ($0.id, $0.score) })
    for meetingID in hybridIDs {
        #expect(
            hybridScores[meetingID] == oracleScores[meetingID],
            "Score differs for meeting \(meetingID) on query \"\(query)\""
        )
    }
}

// MARK: - Graceful Degradation Test

@Suite("Search graceful degradation")
struct SearchGracefulDegradationTests {
    @Test("In-memory store still returns non-transcript matches")
    func inMemoryStoreGracefulDegradation() async throws {
        let store = try DataStore(storage: .inMemory)
        let meetingID = try await store.createMeeting(title: "Budget Review")
        try await store.setNotes("quarterly budget overview", for: meetingID)

        // Add a transcript that would match "budget" if SQL were available.
        let seg = TranscriptSegment(
            speakerID: 0, speakerLabel: "S0",
            startTime: 0, endTime: 5,
            text: "The budget is looking good",
            confidence: 0.9, noSpeechProbability: 0.1, words: nil
        )
        let txResult = TranscriptResult(
            transcriptionMethodId: "v1", language: "en", speakerCount: 1,
            segments: [seg], speakerEmbeddings: [:], processingDuration: 1.0
        )
        let txID = try await store.addTranscript(
            txResult, vocabularyUsed: [], mappedEventIdentifier: nil, to: meetingID
        )
        try await store.setPreferredTranscript(txID, for: meetingID)

        let hits = try await store.searchHits("budget", limit: 50)
        #expect(hits.count == 1, "Title + notes should still match")
        #expect(hits.first?.id == meetingID)
        // Title (3) + notes (1) = 4. Transcript is dropped (no SQL for in-memory).
        #expect(hits.first?.score == 4)
        #expect(hits.first?.matchedFields.contains(.title) == true)
        #expect(hits.first?.matchedFields.contains(.notes) == true)
        // Transcript contribution is absent (graceful degradation).
        #expect(hits.first?.matchedFields.contains(.transcript) == false)
    }
}

// MARK: - Summary Search Tests

@Suite("Search summary field (searchHits)")
struct SearchSummaryTests {
    private func makeStore() throws -> DataStore {
        try DataStore(storage: .inMemory)
    }

    @Test("Summary-only term matches with weight 2")
    func summaryOnlyMatch() async throws {
        let store = try makeStore()
        let meetingID = try await store.createMeeting(title: "Weekly Standup")
        try await store.applyGeneratedSummary(
            "Discussed the new onboarding flow", for: meetingID
        )

        let hits = try await store.searchHits("onboarding", limit: 50)
        #expect(hits.count == 1)
        #expect(hits.first?.id == meetingID)
        #expect(hits.first?.score == 2)
        #expect(hits.first?.matchedFields.contains(.summary) == true)
        #expect(hits.first?.matchedFields.contains(.title) == false)
    }

    @Test("Summary ranked between title and transcript")
    func summaryRankedBelowTitle() async throws {
        let store = try makeStore()
        // Meeting A: "launch" in title (score 3)
        _ = try await store.createMeeting(title: "Launch planning")
        // Meeting B: "launch" only in summary (score 2)
        let meetingB = try await store.createMeeting(title: "Team sync")
        try await store.applyGeneratedSummary(
            "Preparing for the launch next week", for: meetingB
        )

        let hits = try await store.searchHits("launch", limit: 50)
        #expect(hits.count == 2)
        #expect(hits[0].title == "Launch planning")
        #expect(hits[0].matchedFields.contains(.title))
        #expect(hits[1].title == "Team sync")
        #expect(hits[1].matchedFields.contains(.summary))
    }

    @Test("Summary + title both match, scoring additively")
    func summaryAndTitleScoring() async throws {
        let store = try makeStore()
        let meetingID = try await store.createMeeting(title: "Budget Review")
        try await store.applyGeneratedSummary(
            "Reviewed the quarterly budget", for: meetingID
        )

        let hits = try await store.searchHits("budget", limit: 50)
        #expect(hits.count == 1)
        // title (3) + summary (2) = 5
        #expect(hits.first?.score == 5)
        #expect(hits.first?.matchedFields.contains(.title) == true)
        #expect(hits.first?.matchedFields.contains(.summary) == true)
    }

    @Test("Summary field sort order places it between tags and people")
    func summaryFieldSortOrder() async throws {
        let store = try makeStore()
        let meetingID = try await store.createMeeting(title: "Review")
        _ = try await store.createTagAndApply(name: "Review", to: meetingID)
        try await store.applyGeneratedSummary(
            "A review of the review process", for: meetingID
        )

        let hits = try await store.searchHits("review", limit: 50)
        #expect(hits.count == 1)
        let fields = try #require(hits.first?.matchedFields)
        // Sorted order: title, tags, summary
        #expect(fields == [.title, .tags, .summary])
    }
}

// MARK: - Transcript SQL Search Tests (on-disk)

@Suite("Transcript SQL search")
struct TranscriptSQLSearchTests {
    @Test("Transcript-only match found via SQL on disk store")
    func transcriptOnlyMatch() async throws {
        let dir = makeTempDir()
        defer { cleanupDir(dir) }

        let store = try DataStore(storage: .onDisk(dir))
        let meetingID = try await store.createMeeting(title: "Generic Meeting")

        let seg = TranscriptSegment(
            speakerID: 0, speakerLabel: "S0",
            startTime: 0, endTime: 5,
            text: "We discussed the xylophone project extensively",
            confidence: 0.9, noSpeechProbability: 0.1, words: nil
        )
        let txResult = TranscriptResult(
            transcriptionMethodId: "v1", language: "en", speakerCount: 1,
            segments: [seg], speakerEmbeddings: [:], processingDuration: 1.0
        )
        let txID = try await store.addTranscript(
            txResult, vocabularyUsed: [], mappedEventIdentifier: nil, to: meetingID
        )
        try await store.setPreferredTranscript(txID, for: meetingID)

        let hits = try await store.searchHits("xylophone", limit: 50)
        #expect(hits.count == 1)
        #expect(hits.first?.id == meetingID)
        #expect(hits.first?.score == 1)
        #expect(hits.first?.matchedFields == [.transcript])
    }

    @Test("Non-preferred transcript is excluded from search")
    func nonPreferredTranscriptExcluded() async throws {
        let dir = makeTempDir()
        defer { cleanupDir(dir) }

        let store = try DataStore(storage: .onDisk(dir))
        let meetingID = try await store.createMeeting(title: "Meeting")

        // Add two transcripts. Only the preferred one should be searched.
        let seg1 = TranscriptSegment(
            speakerID: 0, speakerLabel: "S0",
            startTime: 0, endTime: 5,
            text: "unicorn rainbow sparkle",
            confidence: 0.9, noSpeechProbability: 0.1, words: nil
        )
        let tx1 = TranscriptResult(
            transcriptionMethodId: "v1", language: "en", speakerCount: 1,
            segments: [seg1], speakerEmbeddings: [:], processingDuration: 1.0
        )
        _ = try await store.addTranscript(
            tx1, vocabularyUsed: [], mappedEventIdentifier: nil, to: meetingID
        )

        let seg2 = TranscriptSegment(
            speakerID: 0, speakerLabel: "S0",
            startTime: 0, endTime: 5,
            text: "normal everyday conversation",
            confidence: 0.9, noSpeechProbability: 0.1, words: nil
        )
        let tx2 = TranscriptResult(
            transcriptionMethodId: "v2", language: "en", speakerCount: 1,
            segments: [seg2], speakerEmbeddings: [:], processingDuration: 1.0
        )
        let tx2ID = try await store.addTranscript(
            tx2, vocabularyUsed: [], mappedEventIdentifier: nil, to: meetingID
        )
        // Set tx2 (no "unicorn") as preferred.
        try await store.setPreferredTranscript(tx2ID, for: meetingID)

        let hits = try await store.searchHits("unicorn", limit: 50)
        #expect(hits.isEmpty, "Non-preferred transcript should not match")
    }

    @Test("Multi-term search scores transcript per term")
    func multiTermTranscriptScoring() async throws {
        let dir = makeTempDir()
        defer { cleanupDir(dir) }

        let store = try DataStore(storage: .onDisk(dir))
        let meetingID = try await store.createMeeting(title: "Weekly")

        let seg = TranscriptSegment(
            speakerID: 0, speakerLabel: "S0",
            startTime: 0, endTime: 10,
            text: "The xylophone and the zeppelin were discussed",
            confidence: 0.9, noSpeechProbability: 0.1, words: nil
        )
        let txResult = TranscriptResult(
            transcriptionMethodId: "v1", language: "en", speakerCount: 1,
            segments: [seg], speakerEmbeddings: [:], processingDuration: 1.0
        )
        let txID = try await store.addTranscript(
            txResult, vocabularyUsed: [], mappedEventIdentifier: nil, to: meetingID
        )
        try await store.setPreferredTranscript(txID, for: meetingID)

        let hits = try await store.searchHits("xylophone zeppelin", limit: 50)
        #expect(hits.count == 1)
        // Each term scores +1 for transcript = 2 total
        #expect(hits.first?.score == 2)
        #expect(hits.first?.matchedFields.contains(.transcript) == true)
    }
}

// MARK: - LIKE Escaping Tests (on-disk)

@Suite("LIKE metacharacter escaping")
struct LikeEscapingTests {
    @Test("Percent in search term matches literal percent only")
    func percentInTerm() async throws {
        let dir = makeTempDir()
        defer { cleanupDir(dir) }

        let store = try DataStore(storage: .onDisk(dir))

        // Meeting A: transcript contains literal "50%"
        let meetingA = try await store.createMeeting(title: "Metrics")
        try await addSegment(
            text: "We achieved 50% of goal this quarter",
            to: meetingA, store: store
        )

        // Meeting B: transcript contains "50" but NOT "50%"
        let meetingB = try await store.createMeeting(title: "Review")
        try await addSegment(
            text: "We had 50 units shipped last week",
            to: meetingB, store: store
        )

        // Without escaping, "50%" becomes LIKE '%50%%' which matches "50" too.
        let hits = try await store.searchHits("50%", limit: 50)
        let transcriptHits = hits.filter { $0.matchedFields.contains(.transcript) }
        #expect(transcriptHits.count == 1, "Only literal '50%' should match")
        #expect(transcriptHits.first?.id == meetingA)
    }

    @Test("Underscore in search term matches literal underscore only")
    func underscoreInTerm() async throws {
        let dir = makeTempDir()
        defer { cleanupDir(dir) }

        let store = try DataStore(storage: .onDisk(dir))

        // Meeting A: transcript contains literal "foo_bar"
        let meetingA = try await store.createMeeting(title: "Code")
        try await addSegment(text: "The foo_bar function is broken", to: meetingA, store: store)

        // Meeting B: transcript contains "fooXbar" (underscore would match any char)
        let meetingB = try await store.createMeeting(title: "Other")
        try await addSegment(text: "The fooXbar module works fine", to: meetingB, store: store)

        let hits = try await store.searchHits("foo_bar", limit: 50)
        let transcriptHits = hits.filter { $0.matchedFields.contains(.transcript) }
        #expect(transcriptHits.count == 1, "Only literal 'foo_bar' should match")
        #expect(transcriptHits.first?.id == meetingA)
    }

    @Test("Bare percent search matches nothing without literal percent")
    func barePercentMatchesNothing() async throws {
        let dir = makeTempDir()
        defer { cleanupDir(dir) }

        let store = try DataStore(storage: .onDisk(dir))

        // Meeting with plain text (no literal % character).
        let meetingID = try await store.createMeeting(title: "Standup")
        try await addSegment(
            text: "Discussed project milestones and deadlines",
            to: meetingID, store: store
        )

        // A bare "%" search without escaping would match every row.
        let hits = try await store.searchHits("%", limit: 50)
        let transcriptHits = hits.filter { $0.matchedFields.contains(.transcript) }
        #expect(transcriptHits.isEmpty, "Bare '%' should not match plain text")
    }
}

// MARK: - Limit Boundary Tests

@Suite("Search limit boundary")
struct SearchLimitBoundaryTests {
    @Test("Tied scores return most recent meetings, not arbitrary subset")
    func limitBoundaryTiedScores() async throws {
        let store = try DataStore(storage: .inMemory)

        let totalCount = 20
        let searchLimit = 10
        var allIDs: [UUID] = []
        for idx in 0 ..< totalCount {
            let meetingID = try await store.createMeeting(title: "Alpha meeting \(idx)")
            // Set explicit dates so ordering is deterministic: idx 0 is oldest.
            // startDate is public var; the in-context modification is visible to
            // searchHits running on the same actor without a save() call.
            try await store.read { dataStore in
                guard let meeting = try dataStore.meeting(id: meetingID) else { return }
                meeting.startDate = Date(timeIntervalSince1970: Double(idx) * 86400)
            }
            allIDs.append(meetingID)
        }

        // All 20 match "alpha" with title weight 3.
        let hits = try await store.searchHits("alpha", limit: searchLimit)
        #expect(hits.count == searchLimit)

        for hit in hits {
            #expect(hit.score == 3)
        }

        // The 10 most recent meetings (idx 10-19) must be returned.
        let expectedIDs = Set(allIDs.suffix(searchLimit))
        let actualIDs = Set(hits.map(\.id))
        #expect(
            actualIDs == expectedIDs,
            "Should return the \(searchLimit) most recent meetings"
        )

        // Results must be sorted by date descending.
        for idx in 0 ..< hits.count - 1 {
            #expect(
                hits[idx].date > hits[idx + 1].date,
                "Results should be sorted by date descending"
            )
        }
    }
}

// MARK: - Projected Assembly Path (gating — runs in `make test`)

/// End-to-end test for the SQL date-projection assembly path. This path fires
/// when `scores.count > limit` on an on-disk store. It sorts+truncates using
/// SQL-projected dates, then fetches only the surviving meetings via SwiftData.
@Suite("Projected assembly path")
struct ProjectedAssemblyPathTests {
    @Test("Projected path returns byte-identical results to direct path")
    func projectedMatchesDirect() async throws {
        let dir = makeTempDir()
        defer { cleanupDir(dir) }

        let store = try DataStore(storage: .onDisk(dir))

        // Create 20 meetings with varying dates. All titles contain "alpha"
        // so they all match a title search, guaranteeing scores.count = 20.
        let totalCount = 20
        let smallLimit = 5
        var allIDs: [UUID] = []
        for idx in 0 ..< totalCount {
            let meetingID = try await store.createMeeting(
                title: "Alpha meeting \(idx)",
                start: Date(timeIntervalSince1970: Double(idx) * 86400)
            )
            allIDs.append(meetingID)
        }

        // Also give some meetings higher scores so the test covers mixed
        // score+date sorting.
        try await store.setNotes("alpha notes", for: allIDs[15])
        try await store.setNotes("alpha notes", for: allIDs[10])

        // Run with smallLimit < totalCount → projected path.
        let projectedHits = try await store.read { dataStore in
            let hits = try dataStore.searchHits("alpha", limit: smallLimit)
            return (hits: hits, usedProjection: dataStore.lastSearchUsedProjection)
        }

        #expect(
            projectedHits.usedProjection == true,
            "Must take the projected path when scores.count (\(totalCount)) > limit (\(smallLimit))"
        )
        #expect(projectedHits.hits.count == smallLimit)

        // Run with a limit above the match count → direct path.
        let directHits = try await store.read { dataStore in
            let hits = try dataStore.searchHits("alpha", limit: totalCount + 10)
            return (hits: hits, usedProjection: dataStore.lastSearchUsedProjection)
        }

        #expect(
            directHits.usedProjection == false,
            "Must take the direct path when scores.count (\(totalCount)) <= limit (\(totalCount + 10))"
        )

        // The projected result must be byte-identical to the first `smallLimit`
        // elements of the direct result. This is the core correctness claim:
        // the projected path differs only in performance, never in results.
        let directPrefix = Array(directHits.hits.prefix(smallLimit))
        #expect(
            projectedHits.hits == directPrefix,
            "Projected top-\(smallLimit) must match direct path's top-\(smallLimit)"
        )

        // Verify sort order: score descending, then date descending.
        for idx in 0 ..< projectedHits.hits.count - 1 {
            let lhs = projectedHits.hits[idx]
            let rhs = projectedHits.hits[idx + 1]
            if lhs.score == rhs.score {
                #expect(lhs.date >= rhs.date, "Tied scores must sort by date descending")
            } else {
                #expect(lhs.score > rhs.score, "Results must sort by score descending")
            }
        }
    }
}

// MARK: - Oracle (test-only reference)

/// The original full-fetch scoring implementation, preserved for differential
/// testing against the hybrid SQL search path. Uses only public DataStore APIs.
/// Does NOT include the `.summary` field (it pre-dates that addition).
extension DataStore {
    // swiftlint:disable:next function_body_length
    func searchHitsOracle(_ query: String, limit: Int) throws -> [SearchHit] {
        let terms = query.lowercased()
            .split(separator: " ")
            .map(String.init)
            .filter { !$0.isEmpty }

        guard !terms.isEmpty else { return [] }

        let all = try fetchAllMeetings()

        var hits: [SearchHit] = all.compactMap { meeting in
            var score = 0
            var matchedFields: Set<SearchField> = []
            let titleLower = meeting.title.lowercased()
            let notesLower = meeting.notes.lowercased()

            for term in terms {
                if titleLower.localizedStandardContains(term) {
                    score += 3
                    matchedFields.insert(.title)
                }
                let participantMatch = meeting.participants.contains {
                    $0.name.lowercased().localizedStandardContains(term)
                }
                let organizerMatch = meeting.organizer.map {
                    $0.name.lowercased().localizedStandardContains(term)
                } ?? false
                if participantMatch || organizerMatch {
                    score += 2
                    matchedFields.insert(.people)
                }
                if let prefID = meeting.preferredTranscriptID,
                   let txRecord = meeting.transcripts.first(where: { $0.id == prefID }),
                   txRecord.segments.contains(where: {
                       $0.text.lowercased().localizedStandardContains(term)
                   })
                {
                    score += 1
                    matchedFields.insert(.transcript)
                }
                if !notesLower.isEmpty, notesLower.localizedStandardContains(term) {
                    score += 1
                    matchedFields.insert(.notes)
                }
                if meeting.tags.contains(where: {
                    $0.name.lowercased().localizedStandardContains(term)
                }) {
                    score += 3
                    matchedFields.insert(.tags)
                }
            }

            guard score > 0 else { return nil }
            return SearchHit(
                id: meeting.id,
                title: meeting.title,
                date: meeting.startDate ?? meeting.createdAt,
                score: score,
                matchedFields: Array(matchedFields).sorted {
                    oracleFieldOrder($0) < oracleFieldOrder($1)
                }
            )
        }

        hits.sort { lhs, rhs in
            if lhs.score != rhs.score { return lhs.score > rhs.score }
            return lhs.date > rhs.date
        }

        return Array(hits.prefix(limit))
    }

    private func oracleFieldOrder(_ field: SearchField) -> Int {
        switch field {
        case .title: 0
        case .tags: 1
        case .summary: 2
        case .people: 3
        case .transcript: 4
        case .notes: 5
        }
    }
}

// MARK: - Helpers

/// Creates a single-segment transcript and sets it as preferred.
private func addSegment(text: String, to meetingID: UUID, store: DataStore) async throws {
    let seg = TranscriptSegment(
        speakerID: 0, speakerLabel: "S0",
        startTime: 0, endTime: 5,
        text: text,
        confidence: 0.9, noSpeechProbability: 0.1, words: nil
    )
    let txResult = TranscriptResult(
        transcriptionMethodId: "v1", language: "en", speakerCount: 1,
        segments: [seg], speakerEmbeddings: [:], processingDuration: 0.5
    )
    let txID = try await store.addTranscript(
        txResult, vocabularyUsed: [], mappedEventIdentifier: nil, to: meetingID
    )
    try await store.setPreferredTranscript(txID, for: meetingID)
}

private func makeTempDir() -> URL {
    let dir = FileManager.default.temporaryDirectory
        .appendingPathComponent("SearchSQLTest-\(UUID().uuidString)")
    // swiftlint:disable:next force_try
    try! FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    return dir
}

private func cleanupDir(_ dir: URL) {
    try? FileManager.default.removeItem(at: dir)
}

// MARK: - Test-only read-only SQLite wrapper

private final class TestReadOnlyDB {
    private var handle: OpaquePointer?

    init(path: String) throws {
        var pointer: OpaquePointer?
        let openResult = sqlite3_open_v2(path, &pointer, SQLITE_OPEN_READONLY, nil)
        guard openResult == SQLITE_OK, let opened = pointer else {
            throw TestSQLiteError(message: "open failed rc=\(openResult)")
        }
        handle = opened
    }

    deinit {
        if let handle { sqlite3_close(handle) }
    }

    func columnNames(table: String) throws -> [String] {
        let sql = "PRAGMA table_info(\(table))"
        var stmt: OpaquePointer?
        let prepareResult = sqlite3_prepare_v2(handle, sql, -1, &stmt, nil)
        guard prepareResult == SQLITE_OK, let prepared = stmt else {
            let msg = handle.flatMap { String(cString: sqlite3_errmsg($0)) } ?? "unknown"
            throw TestSQLiteError(message: "prepare failed: \(msg)")
        }
        defer { sqlite3_finalize(prepared) }

        var names: [String] = []
        while sqlite3_step(prepared) == SQLITE_ROW {
            if let cText = sqlite3_column_text(prepared, 1) {
                names.append(String(cString: cText))
            }
        }
        return names
    }

    /// Returns date-only projections of all meetings: ID -> (startDate, createdAt).
    /// Mirrors `ReadOnlySQLiteDB.meetingDateProjections()` for test assertions.
    func meetingDateProjections() throws -> [UUID: TestMeetingDateProjection] {
        let sql = "SELECT hex(ZID), ZSTARTDATE, ZCREATEDAT FROM ZMEETING"
        var stmt: OpaquePointer?
        let prepareResult = sqlite3_prepare_v2(handle, sql, -1, &stmt, nil)
        guard prepareResult == SQLITE_OK, let prepared = stmt else {
            let msg = handle.flatMap { String(cString: sqlite3_errmsg($0)) } ?? "unknown"
            throw TestSQLiteError(message: "prepare failed: \(msg)")
        }
        defer { sqlite3_finalize(prepared) }

        var result: [UUID: TestMeetingDateProjection] = [:]
        while sqlite3_step(prepared) == SQLITE_ROW {
            guard let hexCStr = sqlite3_column_text(prepared, 0) else { continue }
            let hex = String(cString: hexCStr)
            guard let id = testUUID(fromHex: hex) else { continue }

            let startDate: Date? = if sqlite3_column_type(prepared, 1) != SQLITE_NULL {
                Date(timeIntervalSinceReferenceDate: sqlite3_column_double(prepared, 1))
            } else {
                nil
            }

            let createdAt = if sqlite3_column_type(prepared, 2) != SQLITE_NULL {
                Date(timeIntervalSinceReferenceDate: sqlite3_column_double(prepared, 2))
            } else {
                Date.distantPast
            }

            result[id] = TestMeetingDateProjection(startDate: startDate, createdAt: createdAt)
        }
        return result
    }

    /// Reads Core Data's entity registry from Z_PRIMARYKEY.
    func entityRegistry() throws -> [String: TestEntityEntry] {
        let sql = "SELECT Z_ENT, Z_NAME, Z_SUPER FROM Z_PRIMARYKEY"
        var stmt: OpaquePointer?
        let prepareResult = sqlite3_prepare_v2(handle, sql, -1, &stmt, nil)
        guard prepareResult == SQLITE_OK, let prepared = stmt else {
            let msg = handle.flatMap { String(cString: sqlite3_errmsg($0)) } ?? "unknown"
            throw TestSQLiteError(message: "prepare failed: \(msg)")
        }
        defer { sqlite3_finalize(prepared) }

        var registry: [String: TestEntityEntry] = [:]
        while sqlite3_step(prepared) == SQLITE_ROW {
            let entityNumber = sqlite3_column_int(prepared, 0)
            guard let cName = sqlite3_column_text(prepared, 1) else { continue }
            let name = String(cString: cName)
            let superEntity = sqlite3_column_int(prepared, 2)
            registry[name] = TestEntityEntry(
                entityNumber: entityNumber, superEntity: superEntity
            )
        }
        return registry
    }
}

private struct TestEntityEntry {
    let entityNumber: Int32
    let superEntity: Int32
}

private struct TestMeetingDateProjection {
    let startDate: Date?
    let createdAt: Date
    var effectiveDate: Date {
        startDate ?? createdAt
    }
}

private struct TestSQLiteError: Error {
    let message: String
}

/// Parses a 32-character uppercase hex string into a UUID. Test-only mirror
/// of the production `uuid(fromHex:)` in `SQLiteSegmentSearch.swift`.
private func testUUID(fromHex hex: String) -> UUID? {
    guard hex.count == 32 else { return nil }
    let chars = hex
    let start = chars.startIndex
    let formatted = "\(chars[start ..< chars.index(start, offsetBy: 8)])"
        + "-\(chars[chars.index(start, offsetBy: 8) ..< chars.index(start, offsetBy: 12)])"
        + "-\(chars[chars.index(start, offsetBy: 12) ..< chars.index(start, offsetBy: 16)])"
        + "-\(chars[chars.index(start, offsetBy: 16) ..< chars.index(start, offsetBy: 20)])"
        + "-\(chars[chars.index(start, offsetBy: 20) ..< chars.index(start, offsetBy: 32)])"
    return UUID(uuidString: formatted)
}

// MARK: - Deterministic data generation for differential test

private struct TestLCG: RandomNumberGenerator {
    private var state: UInt64
    init(seed: UInt64) {
        state = seed
    }

    mutating func next() -> UInt64 {
        state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
        return state
    }
}

private let testWords: [String] = [
    "the", "be", "to", "of", "and", "a", "in", "that", "have", "it",
    "for", "not", "on", "with", "as", "you", "do", "at", "this", "but",
    "project", "meeting", "team", "plan", "review", "sprint", "task",
    "update", "progress", "deadline", "budget", "customer", "product",
    "feature", "design", "code", "system", "test", "deploy", "report"
]

private func testSegmentText(rng: inout TestLCG, count: Int) -> String {
    let size = UInt64(testWords.count)
    return (0 ..< count).map { _ in testWords[Int(rng.next() % size)] }.joined(separator: " ")
}
