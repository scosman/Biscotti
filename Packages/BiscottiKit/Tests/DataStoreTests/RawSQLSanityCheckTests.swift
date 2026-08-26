import DataStore
import Foundation
import SQLite3
import Testing

// Can we query the SwiftData store directly with SQL, and is it fast enough to
// skip a real full-text index? Yes: 288x faster than `searchHits` at 5000
// meetings (137 ms vs 39.5 s), with no schema change or migration.
//
// Full results, the validated schema/column names, and the risks are recorded in
// `specs/research/search/README.md` -- read that before changing this file.
//
// SLOW (~2 min): generates stores up to 284 MB. Env-gated
// (BISCOTTI_RUN_SQLCHECK=1) so it never runs in `make test` / `ci` /
// `precommit-checks`. Run via `make bench`.
// Generated data only -- never touches the real store.

private let sqlCheckEnabled = ProcessInfo.processInfo.environment["BISCOTTI_RUN_SQLCHECK"] == "1"

private let rareToken = "xyzorphan"

/// Core Data names an undeclared-inverse FK `Z<entityNumber><parentRelName>`.
/// `ZID` is a 16-byte BLOB, so `hex()` it to read as text.
/// The trailing clause preserves the existing "preferred transcript only" rule.
private let joinSQL = """
SELECT DISTINCT hex(m.ZID)
FROM   ZTRANSCRIPTSEGMENTRECORD s
JOIN   ZTRANSCRIPTRECORD t ON s.Z7SEGMENTS    = t.Z_PK
JOIN   ZMEETING          m ON t.Z4TRANSCRIPTS = m.Z_PK
WHERE  s.ZTEXT LIKE '%__TERM__%'
  AND  t.ZID = m.ZPREFERREDTRANSCRIPTID
"""

/// The same scan without the joins, to isolate join cost from scan cost.
private let scanOnlySQL = """
SELECT COUNT(*) FROM ZTRANSCRIPTSEGMENTRECORD
WHERE ZTEXT LIKE '%__TERM__%'
"""

// MARK: - Generation (self-contained; mirrors the benchmark generator)

private struct LCG: RandomNumberGenerator {
    private var state: UInt64
    init(seed: UInt64) {
        state = seed
    }

    mutating func next() -> UInt64 {
        state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
        return state
    }
}

private let words: [String] = [
    "the", "be", "to", "of", "and", "a", "in", "that", "have", "it",
    "for", "not", "on", "with", "as", "you", "do", "at", "this", "but",
    "by", "from", "they", "we", "say", "or", "an", "will", "one", "all",
    "project", "meeting", "team", "plan", "review", "sprint", "task",
    "update", "progress", "deadline", "schedule", "budget", "customer",
    "product", "feature", "design", "development", "testing", "deployment",
    "release", "milestone", "roadmap", "strategy", "objective", "requirement",
    "analysis", "architecture", "implementation", "code", "function",
    "system", "interface", "database", "service", "platform", "integration",
    "framework", "library", "application", "performance", "optimization",
    "security", "documentation", "collaboration", "workflow", "presentation",
    "discussion", "feedback", "iteration", "improvement", "quality",
    "process", "communication", "leadership", "management", "engineering",
    "innovation", "technology", "solution", "component", "module", "version",
    "build", "test", "deploy", "monitor", "network", "report", "target",
    "scope", "risk", "cost", "value", "growth"
]

private func segmentText(rng: inout LCG, count: Int) -> String {
    let size = UInt64(words.count)
    return (0 ..< count).map { _ in words[Int(rng.next() % size)] }.joined(separator: " ")
}

private func populate(
    _ store: DataStore, count: Int, segCount: Int, wordsPerSeg: Int, rareIndices: Set<Int>
) async throws {
    let batchSize = min(500, count)
    for batchStart in stride(from: 0, to: count, by: batchSize) {
        let batchEnd = min(batchStart + batchSize, count)
        var titles: [String] = []
        var allSegs: [[String]] = []
        for idx in batchStart ..< batchEnd {
            var rng = LCG(seed: UInt64(idx) &* 2_654_435_761)
            titles.append("Meeting \(idx)")
            var segs = (0 ..< segCount).map { _ in
                segmentText(rng: &rng, count: wordsPerSeg)
            }
            if rareIndices.contains(idx), !segs.isEmpty {
                segs[0] = rareToken + " " + segs[0]
            }
            allSegs.append(segs)
        }
        try await store.bulkInsertMeetingsWithTranscripts(titles: titles, segmentTexts: allSegs)
    }
}

// MARK: - Minimal read-only SQLite wrapper

private struct SQLiteError: Error { let message: String }

private final class ReadOnlyDB {
    private var handle: OpaquePointer?

    init(path: String) throws {
        var pointer: OpaquePointer?
        let openResult = sqlite3_open_v2(path, &pointer, SQLITE_OPEN_READONLY, nil)
        guard openResult == SQLITE_OK, let opened = pointer else {
            throw SQLiteError(message: "open failed rc=\(openResult)")
        }
        handle = opened
    }

    deinit {
        if let handle { sqlite3_close(handle) }
    }

    /// Runs a query, returning rows of stringified column values.
    func query(_ sql: String) throws -> [[String]] {
        var stmt: OpaquePointer?
        let prepareResult = sqlite3_prepare_v2(handle, sql, -1, &stmt, nil)
        guard prepareResult == SQLITE_OK, let prepared = stmt else {
            let msg = String(cString: sqlite3_errmsg(handle))
            throw SQLiteError(message: "prepare failed: \(msg)")
        }
        defer { sqlite3_finalize(prepared) }

        var rows: [[String]] = []
        while sqlite3_step(prepared) == SQLITE_ROW {
            let colCount = sqlite3_column_count(prepared)
            var row: [String] = []
            for col in 0 ..< colCount {
                if let cText = sqlite3_column_text(prepared, col) {
                    row.append(String(cString: cText))
                } else {
                    row.append("NULL")
                }
            }
            rows.append(row)
        }
        return rows
    }
}

// MARK: - Helpers

private func ms(_ duration: Duration) -> Double {
    let (seconds, atto) = duration.components
    return Double(seconds) * 1000.0 + Double(atto) / 1_000_000_000_000_000.0
}

private func tempDir() throws -> URL {
    let dir = FileManager.default.temporaryDirectory
        .appendingPathComponent("SQLCheck-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    return dir
}

private struct QueryTiming {
    let coldMs: Double
    let warmMedianMs: Double
    let rows: [[String]]
}

/// Runs the query once cold, then `reps` warm; reports the warm median.
private func timeQuery(_ database: ReadOnlyDB, _ sql: String, reps: Int = 3) throws -> QueryTiming {
    let coldStart = ContinuousClock.now
    var rows = try database.query(sql)
    let cold = ms(ContinuousClock.now - coldStart)

    var timings: [Double] = []
    for _ in 0 ..< reps {
        let start = ContinuousClock.now
        rows = try database.query(sql)
        timings.append(ms(ContinuousClock.now - start))
    }
    let sorted = timings.sorted()
    return QueryTiming(coldMs: cold, warmMedianMs: sorted[sorted.count / 2], rows: rows)
}

/// Prints the table list and the columns of the three tables the query joins.
private func dumpSchema(_ database: ReadOnlyDB) throws {
    print("\n--- Tables ---")
    let tables = try database.query(
        "SELECT name FROM sqlite_master WHERE type='table' "
            + "AND name NOT LIKE 'sqlite_%' ORDER BY name"
    )
    print(tables.map { $0[0] }.joined(separator: ", "))

    for table in ["ZMEETING", "ZTRANSCRIPTRECORD", "ZTRANSCRIPTSEGMENTRECORD"] {
        print("\n--- \(table) columns ---")
        let cols = try database.query("PRAGMA table_info(\(table))")
        print(cols.map { "\($0[1]):\($0[2])" }.joined(separator: ", "))
    }
}

/// Times the join query and the scan-only variant for both a rare and a common term.
private func reportTimings(_ database: ReadOnlyDB) {
    print("\n  Query                          Cold ms    Warm ms   Meetings")
    print("  " + String(repeating: "-", count: 62))

    for (label, term) in [("rare \"\(rareToken)\"", rareToken), ("common \"the\"", "the")] {
        for (variant, template) in [("", joinSQL), (" [scan only]", scanOnlySQL)] {
            let sql = template.replacingOccurrences(of: "__TERM__", with: term)
            do {
                let result = try timeQuery(database, sql)
                let rowsLabel = variant.isEmpty
                    ? "\(result.rows.count)"
                    : (result.rows.first?.first ?? "?") + " segs"
                let line = "  "
                    + (label + variant).padding(toLength: 30, withPad: " ", startingAt: 0)
                    + String(format: "%8.1f  %8.1f   ", result.coldMs, result.warmMedianMs)
                    + rowsLabel
                print(line)
            } catch {
                print("  \(label)\(variant): FAILED -- \(error)")
            }
        }
    }
}

/// Generates a store at `tierCount` meetings, then measures and verifies the SQL path.
private func runTier(tierCount: Int, dumpSchemaForTier: Bool) async throws {
    let dir = try tempDir()
    defer { try? FileManager.default.removeItem(at: dir) }

    print("\n=================== \(tierCount) meetings ===================")

    let rareIndices: Set<Int> = [0, tierCount / 2]
    let popStart = ContinuousClock.now
    do {
        let writeStore = try DataStore(storage: .onDisk(dir))
        try await populate(
            writeStore, count: tierCount, segCount: 100,
            wordsPerSeg: 50, rareIndices: rareIndices
        )
    }
    print(String(format: "Populated in %.1f s", ms(ContinuousClock.now - popStart) / 1000))

    let dbPath = dir.appending(path: "Biscotti.store").path
    let fileSize = (try? FileManager.default.attributesOfItem(atPath: dbPath)[.size] as? Int) ?? 0
    print("Store size: \(fileSize / 1_000_000) MB")

    let database = try ReadOnlyDB(path: dbPath)
    if dumpSchemaForTier {
        try dumpSchema(database)
    }

    let segRows = try database.query("SELECT COUNT(*) FROM ZTRANSCRIPTSEGMENTRECORD")
    print("\nSegment rows: \(segRows.first?.first ?? "?")")

    reportTimings(database)

    // Correctness: the SQL path must find the same meetings as the Swift path.
    let readStore = try DataStore(storage: .onDisk(dir))
    let swiftHits = try await readStore.read { try $0.searchHits(rareToken, limit: 10000) }
    let sqlRows = try database.query(
        joinSQL.replacingOccurrences(of: "__TERM__", with: rareToken)
    )
    print("\nCorrectness (rare term): swift=\(swiftHits.count) sql=\(sqlRows.count)")
    #expect(
        swiftHits.count == sqlRows.count,
        "SQL path must find the same meetings as the Swift path"
    )
}

// MARK: - The spike

@Suite("Raw SQL sanity check (BISCOTTI_RUN_SQLCHECK=1)",
       .enabled(if: sqlCheckEnabled), .serialized)
struct RawSQLSanityCheckTests {
    @Test("Schema shape + raw SQL search timing", .timeLimit(.minutes(30)))
    func check() async throws {
        for (tierIndex, tierCount) in [50, 500, 5000].enumerated() {
            try await runTier(tierCount: tierCount, dumpSchemaForTier: tierIndex == 0)
        }
    }
}
