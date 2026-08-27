import DataStore
import Foundation
import Testing

// Benchmark for the FTS5 side-index against generated datasets at several
// meeting counts.
//
// Costs are split into cold (full reconcile from scratch), warm (index up to
// date), incremental (history-delta after adding meetings), and index size on
// disk. The linear-scan fetch+fault cost is reported as a baseline -- it is
// what the index replaced.
//
// A raw-SQL LIKE path against the SwiftData store file was benchmarked here
// too, until FTS5 won decisively (see the research doc). It was removed rather
// than maintained: it depended on undeclared Core Data column names and was
// never shipped. The measurements that settled it are preserved in
// `specs/research/search/README.md`.
//
// Results and analysis: `specs/research/search/README.md`.
//
// The full suite is SLOW (~10 min) and generates stores up to 284 MB, so it is
// env-gated (BISCOTTI_RUN_BENCH=1) and never runs in `make test` / `ci` /
// `precommit-checks`. Run via `make bench`. The smoke suite below is fast
// (~30 ms) and DOES run in `make test`, to catch rot in the generator/harness.

// MARK: - Configuration

private let isBenchEnabled = ProcessInfo.processInfo.environment["BISCOTTI_RUN_BENCH"] == "1"

/// Rare search token planted in a small number of meetings.
private let rareToken = "xyzorphan"

/// Number of warm iterations per query (median is reported).
private let warmRuns = 3

/// The `limit` parameter passed to `searchHits`.
private let searchLimit = 50

/// Number of meetings to add for the incremental-sync cost measurement.
private let incrementalBatchSizes = [1, 10, 50]

// MARK: - Deterministic RNG

/// Linear congruential generator with a fixed seed for reproducible text.
private struct SeededRNG: RandomNumberGenerator {
    private var state: UInt64

    init(seed: UInt64) {
        state = seed
    }

    mutating func next() -> UInt64 {
        state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
        return state
    }
}

// MARK: - Word Pool

/// Common English words plus meeting/tech domain terms (~160 entries).
/// "the" appears once in the pool so it shows up in roughly 1/160 of
/// generated words (~31 times per 5000-word transcript).
private let wordPool: [String] = [
    "the", "be", "to", "of", "and", "a", "in", "that", "have", "it",
    "for", "not", "on", "with", "as", "you", "do", "at", "this", "but",
    "by", "from", "they", "we", "say", "or", "an", "will", "one", "all",
    "would", "there", "their", "what", "so", "up", "out", "if", "about",
    "who", "get", "which", "go", "when", "make", "can", "like", "time",
    "no", "just", "know", "take", "people", "into", "year", "good", "some",
    "could", "them", "see", "other", "than", "then", "now", "look", "only",
    "come", "its", "over", "think", "also", "back", "after", "use", "two",
    "how", "our", "work", "first", "well", "way", "even", "new", "want",
    "because", "any", "these", "give", "day", "most", "project", "meeting",
    "team", "plan", "review", "sprint", "task", "update", "progress",
    "deadline", "schedule", "budget", "customer", "product", "feature",
    "design", "development", "testing", "deployment", "release", "milestone",
    "roadmap", "strategy", "objective", "requirement", "specification",
    "analysis", "architecture", "implementation", "code", "function",
    "system", "interface", "database", "service", "platform", "integration",
    "framework", "library", "application", "performance", "optimization",
    "security", "documentation", "collaboration", "workflow", "presentation",
    "discussion", "feedback", "iteration", "improvement", "quality",
    "assurance", "process", "communication", "leadership", "management",
    "engineering", "innovation", "technology", "solution", "component",
    "module", "version", "build", "test", "deploy", "monitor", "network",
    "report", "target", "scope", "risk", "cost", "value", "growth"
]

// MARK: - Data Generation

/// Generates a single segment's text by sampling the word pool.
private func generateSegmentText(rng: inout SeededRNG, wordCount: Int) -> String {
    let poolSize = UInt64(wordPool.count)
    return (0 ..< wordCount).map { _ in
        wordPool[Int(rng.next() % poolSize)]
    }.joined(separator: " ")
}

/// Builds title and segment texts for one meeting.
private func makeMeetingData(
    index: Int,
    segmentCount: Int,
    wordsPerSegment: Int,
    plantRare: Bool
) -> (title: String, segments: [String]) {
    var rng = SeededRNG(seed: UInt64(index) &* 2_654_435_761)
    let adjective = wordPool[Int(rng.next() % UInt64(wordPool.count))]
    let title = "Meeting \(index) \(adjective)"

    var segments = (0 ..< segmentCount).map { _ in
        generateSegmentText(rng: &rng, wordCount: wordsPerSegment)
    }

    if plantRare, !segments.isEmpty {
        segments[0] = rareToken + " " + segments[0]
    }

    return (title, segments)
}

// MARK: - Population

/// Fills a store with meetings (batch-inserted for speed).
private func populateStore(
    _ store: DataStore,
    count: Int,
    segCount: Int,
    wordsPerSeg: Int,
    rareIndices: Set<Int>,
    indexOffset: Int = 0
) async throws {
    let batchSize = min(500, count)
    for batchStart in stride(from: 0, to: count, by: batchSize) {
        let batchEnd = min(batchStart + batchSize, count)
        var titles: [String] = []
        var allSegTexts: [[String]] = []

        for idx in batchStart ..< batchEnd {
            let data = makeMeetingData(
                index: idx + indexOffset,
                segmentCount: segCount,
                wordsPerSegment: wordsPerSeg,
                plantRare: rareIndices.contains(idx)
            )
            titles.append(data.title)
            allSegTexts.append(data.segments)
        }

        try await store.bulkInsertMeetingsWithTranscripts(titles: titles, segmentTexts: allSegTexts)

        if count >= 100, batchEnd % 500 == 0 || batchEnd == count {
            print("    \(batchEnd)/\(count)")
        }
    }
}

// MARK: - FTS5 Measurement

private struct TimingResult {
    let millis: Double
    let hitCount: Int
}

/// Measures a single `searchHits` call (FTS5-backed) on the DataStore actor.
private func measureFTS5Search(
    store: DataStore, query: String, limit: Int = searchLimit
) async throws -> TimingResult {
    try await store.read { dataStore in
        let start = ContinuousClock.now
        let hits = try dataStore.searchHits(query, limit: limit)
        let elapsed = ContinuousClock.now - start
        return TimingResult(millis: durationMs(elapsed), hitCount: hits.count)
    }
}

/// Measures fetch + relationship faulting without string matching.
/// This was the bottleneck in the old linear-scan implementation
/// (object materialization dominated).
private func measureFetchFault(store: DataStore) async throws -> Double {
    try await store.read { dataStore in
        let start = ContinuousClock.now
        let meetings = try dataStore.fetchAllMeetings()
        for meeting in meetings {
            _ = meeting.title
            _ = meeting.notes
            for person in meeting.participants {
                _ = person.name
            }
            _ = meeting.organizer?.name
            for tag in meeting.tags {
                _ = tag.name
            }
            if let pid = meeting.preferredTranscriptID,
               let transcript = meeting.transcripts.first(where: { $0.id == pid })
            {
                for seg in transcript.segments {
                    _ = seg.text
                }
            }
        }
        return durationMs(ContinuousClock.now - start)
    }
}

// MARK: - Statistics

private func durationMs(_ duration: Duration) -> Double {
    let (seconds, atto) = duration.components
    return Double(seconds) * 1000.0 + Double(atto) / 1_000_000_000_000_000.0
}

private func median(_ values: [Double]) -> Double {
    let sorted = values.sorted()
    let count = sorted.count
    guard count > 0 else { return 0 }
    return count.isMultiple(of: 2)
        ? (sorted[count / 2 - 1] + sorted[count / 2]) / 2.0
        : sorted[count / 2]
}

private func spreadStr(_ values: [Double]) -> String {
    guard values.count > 1,
          let maxVal = values.max(),
          let minVal = values.min()
    else { return "-" }
    let range = maxVal - minVal
    return range < 1.0 ? "<1" : String(format: "%.1f", range)
}

// MARK: - Formatting helpers

private func padRight(_ text: String, _ width: Int) -> String {
    text.count >= width ? text : text + String(repeating: " ", count: width - text.count)
}

private func padLeft(_ text: String, _ width: Int) -> String {
    text.count >= width ? text : String(repeating: " ", count: width - text.count) + text
}

private func hardwareInfo() -> String {
    let model = sysctlString("hw.model") ?? "unknown"
    let ramGB = ProcessInfo.processInfo.physicalMemory / (1024 * 1024 * 1024)
    let osVersion = ProcessInfo.processInfo.operatingSystemVersion
    return "\(model), \(ramGB) GB RAM"
        + " | macOS \(osVersion.majorVersion).\(osVersion.minorVersion).\(osVersion.patchVersion)"
}

private func sysctlString(_ name: String) -> String? {
    var size = 0
    sysctlbyname(name, nil, &size, nil, 0)
    guard size > 0 else { return nil }
    var buffer = [CChar](repeating: 0, count: size)
    sysctlbyname(name, &buffer, &size, nil, 0)
    return String(cString: buffer)
}

// MARK: - Report types

private struct QueryResult {
    let label: String
    let warmMedianMs: Double
    let warmSpread: String
    let hitCount: Int
}

private struct IncrementalResult {
    let batchSize: Int
    let millis: Double
    let hitCount: Int
}

private struct TierReport {
    let meetingCount: Int
    let wordsPerMeeting: Int
    let populateMs: Double
    // FTS5
    let fts5ColdMs: Double
    let fts5ColdHits: Int
    let fts5Warm: [QueryResult]
    let fts5Incremental: [IncrementalResult]
    /// Baseline
    let fetchFaultMs: Double
    /// On-disk size of `SearchIndex.sqlite` (+ WAL) after the cold reconcile.
    /// The FTS5 table stores the source text, so this is the price paid for
    /// `bm25()` ranking and `snippet()` excerpts.
    let indexBytes: Int64
    /// On-disk size of the SwiftData store, for scale.
    let storeBytes: Int64
}

// MARK: - Report printer

private func printReport(tiers: [TierReport]) {
    let divider = String(repeating: "=", count: 72)

    print("")
    print(divider)
    print("  Search Benchmark — FTS5 vs Raw SQL (head-to-head)")
    print("  \(hardwareInfo())")
    print(divider)

    for tier in tiers {
        print("")
        print("--- \(tier.meetingCount) meetings (\(tier.wordsPerMeeting) words each) ---")
        print(String(format: "  Populated in %.1f s", tier.populateMs / 1000.0))

        printFTS5Section(tier)
        printBaselineSection(tier)
    }

    print("")
    print(divider)
    print("")
}

private func printFTS5Section(_ tier: TierReport) {
    print("")
    print("  FTS5 COLD (full reconcile — first search on fresh index):")
    print(String(
        format: "    %8.1f ms  (%d hits)",
        tier.fts5ColdMs, tier.fts5ColdHits
    ))

    print("")
    let header = "  \(padRight("FTS5 WARM Query", 32)) \(padLeft("Warm ms", 8))"
        + "  \(padLeft("Spread", 6))  \(padLeft("Hits", 5))"
    print(header)
    print("  \(String(repeating: "-", count: 55))")
    for result in tier.fts5Warm {
        let line = "  \(padRight(result.label, 32)) "
            + "\(padLeft(String(format: "%.1f", result.warmMedianMs), 8))  "
            + "\(padLeft(result.warmSpread, 6))  "
            + "\(padLeft("\(result.hitCount)", 5))"
        print(line)
    }

    print("")
    let ratio = tier.storeBytes > 0
        ? Double(tier.indexBytes) / Double(tier.storeBytes) * 100 : 0
    print(String(
        format: "  FTS5 INDEX SIZE: %.1f MB  (SwiftData store %.1f MB, %.0f%% of it)",
        megabytes(tier.indexBytes), megabytes(tier.storeBytes), ratio
    ))

    print("")
    print("  FTS5 INCREMENTAL (sync + search after adding N meetings):")
    for result in tier.fts5Incremental {
        print(String(
            format: "    +%3d meetings: %8.1f ms  (%d hits)",
            result.batchSize, result.millis, result.hitCount
        ))
    }
}

private func printBaselineSection(_ tier: TierReport) {
    print("")
    print(String(
        format: "  BASELINE (linear scan, fetch+fault every meeting): %.1f ms",
        tier.fetchFaultMs
    ))
}

// MARK: - Temp-dir helpers

private func makeTempDir() -> URL {
    let dir = FileManager.default.temporaryDirectory
        .appendingPathComponent("SearchBench-\(UUID().uuidString)")
    // swiftlint:disable:next force_try
    try! FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    return dir
}

private func cleanupDir(_ dir: URL) {
    try? FileManager.default.removeItem(at: dir)
}

/// Total bytes of a SQLite database, including its WAL and shared-memory
/// sidecars -- in WAL mode a large share of recent writes can still be in
/// the `-wal` file, so the main file alone understates the real size.
private func sqliteBytes(_ base: URL) -> Int64 {
    ["", "-wal", "-shm"].reduce(into: Int64(0)) { total, suffix in
        let path = base.path + suffix
        let attrs = try? FileManager.default.attributesOfItem(atPath: path)
        total += (attrs?[.size] as? NSNumber)?.int64Value ?? 0
    }
}

private func megabytes(_ bytes: Int64) -> Double {
    Double(bytes) / (1024 * 1024)
}

// ===================================================================
// MARK: - Smoke Test (always runs in make test)

// ===================================================================

/// Fast validation that the data generator and measurement harness work.
/// Runs with every `make test` invocation (5 meetings, ~50 words each).
@Suite("Search benchmark smoke")
struct SearchBenchmarkSmokeTests {
    @Test("Data generator and measurement harness validate end-to-end",
          .timeLimit(.minutes(1)))
    func smoke() async throws {
        let dir = makeTempDir()
        defer { cleanupDir(dir) }

        let store = try DataStore(storage: .onDisk(dir))
        try await populateStore(
            store, count: 5, segCount: 1, wordsPerSeg: 50, rareIndices: [1]
        )

        // FTS5: first call triggers full reconcile (index build).
        let titleHits = try await store.read { try $0.searchHits("meeting", limit: 10) }
        #expect(titleHits.count == 5, "every title starts with 'Meeting'")

        // FTS5: rare token planted in exactly 1 meeting.
        let rareHits = try await store.read { try $0.searchHits(rareToken, limit: 10) }
        #expect(rareHits.count == 1, "rare token planted in 1 meeting")

        // FTS5 measurement harness produces a positive duration.
        let timing = try await measureFTS5Search(store: store, query: "meeting")
        #expect(timing.millis > 0, "measurement should produce a positive duration")
        #expect(timing.hitCount == 5)

        // Fetch+fault measurement works.
        let fetchMs = try await measureFetchFault(store: store)
        #expect(fetchMs > 0, "fetch+fault should produce a positive duration")

        // Incremental: add a meeting and verify FTS5 picks it up.
        try await populateStore(
            store, count: 1, segCount: 1, wordsPerSeg: 50,
            rareIndices: [], indexOffset: 100
        )
        let afterIncremental = try await store.read { try $0.searchHits("meeting", limit: 10) }
        #expect(afterIncremental.count == 6, "incremental sync should pick up the new meeting")
    }
}

// ===================================================================
// MARK: - Full Benchmark (env-gated: BISCOTTI_RUN_BENCH=1)

// ===================================================================

// MARK: - FTS5 measurement helpers

/// Measures warm FTS5 search latency for a set of queries on a store whose
/// index is already built. Returns one `QueryResult` per query.
private func measureFTS5WarmQueries(
    store: DataStore,
    queries: [(label: String, query: String)]
) async throws -> [QueryResult] {
    var results: [QueryResult] = []
    for (label, query) in queries {
        var warmValues: [Double] = []
        var hitCount = 0
        for _ in 0 ..< warmRuns {
            let result = try await measureFTS5Search(store: store, query: query)
            warmValues.append(result.millis)
            hitCount = result.hitCount
        }
        results.append(QueryResult(
            label: label,
            warmMedianMs: median(warmValues),
            warmSpread: spreadStr(warmValues), hitCount: hitCount
        ))
    }
    return results
}

/// Measures FTS5 incremental-sync cost: inserts meetings, then searches.
private func measureFTS5Incremental(
    store: DataStore,
    baseCount: Int,
    segCount: Int,
    wordsPerSeg: Int
) async throws -> [IncrementalResult] {
    var results: [IncrementalResult] = []
    for batchSize in incrementalBatchSizes {
        try await populateStore(
            store, count: batchSize, segCount: segCount,
            wordsPerSeg: wordsPerSeg, rareIndices: [],
            indexOffset: baseCount + 10000 * batchSize
        )
        let result = try await measureFTS5Search(store: store, query: rareToken)
        results.append(IncrementalResult(
            batchSize: batchSize, millis: result.millis,
            hitCount: result.hitCount
        ))
    }
    return results
}

// MARK: - Fetch+fault baseline

/// Measures fetch+fault baseline (median of `warmRuns` iterations).
private func measureFetchFaultBaseline(store: DataStore) async throws -> Double {
    var values: [Double] = []
    for _ in 0 ..< warmRuns {
        try await values.append(measureFetchFault(store: store))
    }
    return median(values)
}

// MARK: - Per-tier benchmark runner

/// Measures both FTS5 and raw-SQL search against the same generated store.
private func runTier(meetingCount: Int) async throws -> TierReport {
    let segCount = 100
    let wordsPerSeg = 50

    print("\n==> Tier: \(meetingCount) meetings")

    let dir = makeTempDir()
    defer { cleanupDir(dir) }

    let rareIndices: Set<Int> = [0, meetingCount / 2]

    // Populate the SwiftData store. Use a separate DataStore for writes,
    // then deallocate so the measurement DataStore starts fresh.
    let populateMs: Double
    do {
        let popStart = ContinuousClock.now
        let writeStore = try DataStore(storage: .onDisk(dir))
        try await populateStore(
            writeStore, count: meetingCount, segCount: segCount,
            wordsPerSeg: wordsPerSeg, rareIndices: rareIndices
        )
        populateMs = durationMs(ContinuousClock.now - popStart)
    }

    let queries: [(label: String, query: String)] = [
        ("common \"the\"", "the"),
        ("rare \"\(rareToken)\"", rareToken),
        ("multi \"meeting project\"", "meeting project"),
        ("multi+rare", "the \(rareToken)")
    ]

    // --- FTS5 cold + warm (index exactly `meetingCount` meetings) ---
    let store = try DataStore(storage: .onDisk(dir))
    let fts5Cold = try await measureFTS5Search(store: store, query: rareToken)
    let fts5Warm = try await measureFTS5WarmQueries(store: store, queries: queries)

    // Index size after the cold reconcile, before incremental adds, so it
    // corresponds to exactly `meetingCount` meetings.
    let indexBytes = sqliteBytes(dir.appending(path: "SearchIndex.sqlite"))
    let storeBytes = sqliteBytes(dir.appending(path: "Biscotti.store"))

    // --- Baseline (same store, same meeting count) ---
    let fetchFaultMs = try await measureFetchFaultBaseline(store: store)

    // --- FTS5 incremental (adds meetings AFTER raw SQL + baseline) ---
    let fts5Incremental = try await measureFTS5Incremental(
        store: store, baseCount: meetingCount,
        segCount: segCount, wordsPerSeg: wordsPerSeg
    )

    return TierReport(
        meetingCount: meetingCount,
        wordsPerMeeting: segCount * wordsPerSeg,
        populateMs: populateMs,
        fts5ColdMs: fts5Cold.millis,
        fts5ColdHits: fts5Cold.hitCount,
        fts5Warm: fts5Warm,
        fts5Incremental: fts5Incremental,
        fetchFaultMs: fetchFaultMs,
        indexBytes: indexBytes,
        storeBytes: storeBytes
    )
}

/// Head-to-head benchmark at 50 / 500 / 5000 meetings with ~5000 words each.
/// Excluded from `make test` and `make ci`. Run via `make bench`.
@Suite("Search benchmark full (BISCOTTI_RUN_BENCH=1)",
       .enabled(if: isBenchEnabled), .serialized)
struct SearchBenchmarkFullTests {
    @Test("FTS5 vs raw SQL at 50 / 500 / 5000 meetings",
          .timeLimit(.minutes(30)))
    func benchmark() async throws {
        var allTiers: [TierReport] = []
        for tierCount in [50, 500, 5000] {
            try await allTiers.append(runTier(meetingCount: tierCount))
        }
        printReport(tiers: allTiers)
    }
}
