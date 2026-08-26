import DataStore
import Foundation
import Testing

// Benchmarks the CURRENT `searchHits` implementation (full fetch + in-memory
// scoring). Results and analysis: `specs/research/search/README.md`.
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
    rareIndices: Set<Int>
) async throws {
    let batchSize = min(500, count)
    for batchStart in stride(from: 0, to: count, by: batchSize) {
        let batchEnd = min(batchStart + batchSize, count)
        var titles: [String] = []
        var allSegTexts: [[String]] = []

        for idx in batchStart ..< batchEnd {
            let data = makeMeetingData(
                index: idx,
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

// MARK: - Measurement

private struct TimingResult {
    let millis: Double
    let hitCount: Int
}

/// Measures a single `searchHits` call on the DataStore actor.
private func measureSearch(
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
/// Accesses the same fields as `scoreMeeting` but skips `localizedStandardContains`.
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
    let coldMs: Double
    let warmMedianMs: Double
    let warmSpread: String
    let hitCount: Int // -1 = not applicable (fetch-only row)
}

private struct TierReport {
    let meetingCount: Int
    let wordsPerMeeting: Int
    let populateMs: Double
    let results: [QueryResult]
}

private func printReport(tiers: [TierReport]) {
    let divider = String(repeating: "=", count: 72)

    print("")
    print(divider)
    print("  Search Benchmark Report")
    print("  \(hardwareInfo())")
    print(divider)

    for tier in tiers {
        print("")
        print("--- \(tier.meetingCount) meetings (\(tier.wordsPerMeeting) words each) ---")
        print(String(format: "  Populated in %.1f s", tier.populateMs / 1000.0))
        print("")
        let header = "  \(padRight("Query", 32)) \(padLeft("Cold ms", 8))"
            + "  \(padLeft("Warm ms", 8))  \(padLeft("Spread", 6))  \(padLeft("Hits", 5))"
        print(header)
        print("  \(String(repeating: "-", count: 65))")

        var fetchFaultWarm: Double?
        var rareSearchWarm: Double?
        var commonSearchWarm: Double?

        for result in tier.results {
            let hitsStr = result.hitCount >= 0 ? "\(result.hitCount)" : "-"
            let line = "  \(padRight(result.label, 32)) \(padLeft(String(format: "%.1f", result.coldMs), 8))  "
                + "\(padLeft(String(format: "%.1f", result.warmMedianMs), 8))  "
                + "\(padLeft(result.warmSpread, 6))  \(padLeft(hitsStr, 5))"
            print(line)

            if result.label.hasPrefix("fetch") { fetchFaultWarm = result.warmMedianMs }
            if result.label.hasPrefix("rare") { rareSearchWarm = result.warmMedianMs }
            if result.label.hasPrefix("common") { commonSearchWarm = result.warmMedianMs }
        }

        printBreakdown(
            fetchWarm: fetchFaultWarm,
            rareWarm: rareSearchWarm,
            commonWarm: commonSearchWarm
        )
    }

    print("")
    print(divider)
    print("")
}

/// Prints the fetch-vs-score breakdown, comparing rare search (worst case,
/// no short-circuit) against fetch+fault to isolate string-matching cost.
private func printBreakdown(
    fetchWarm: Double?,
    rareWarm: Double?,
    commonWarm: Double?
) {
    guard let fetch = fetchWarm, let rare = rareWarm else { return }
    let scoringMs = max(rare - fetch, 0)
    let scorePct = rare > 0 ? Int((scoringMs / rare) * 100) : 0

    print("")
    print("  Fetch vs Score (warm, rare term = worst case, no short-circuit):")
    print(String(
        format: "    fetch+fault: %7.1f ms   scoring: %7.1f ms (%d%%)",
        fetch, scoringMs, scorePct
    ))
    if let common = commonWarm {
        print(String(
            format: "    common-term search: %.1f ms (much faster -- contains(where:)",
            common
        ))
        print("    short-circuits on the first matching segment)")
    }
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

        // Every title starts with "Meeting" so a title search should match all 5
        let titleHits = try await store.read { try $0.searchHits("meeting", limit: 10) }
        #expect(titleHits.count == 5, "every title starts with 'Meeting'")

        // Rare token planted in exactly 1 meeting
        let rareHits = try await store.read { try $0.searchHits(rareToken, limit: 10) }
        #expect(rareHits.count == 1, "rare token planted in 1 meeting")

        // Measurement harness produces a positive duration
        let timing = try await measureSearch(store: store, query: "meeting")
        #expect(timing.millis > 0, "measurement should produce a positive duration")
        #expect(timing.hitCount == 5)

        // Fetch+fault measurement works
        let fetchMs = try await measureFetchFault(store: store)
        #expect(fetchMs > 0, "fetch+fault should produce a positive duration")
    }
}

// ===================================================================
// MARK: - Full Benchmark (env-gated: BISCOTTI_RUN_BENCH=1)

// ===================================================================

// MARK: - Per-tier benchmark runner

/// Measures cold/warm search for each query type and fetch+fault at one tier.
private func runTier(meetingCount: Int) async throws -> TierReport {
    let segCount = 100
    let wordsPerSeg = 50

    print("\n==> Tier: \(meetingCount) meetings")

    let dir = makeTempDir()
    defer { cleanupDir(dir) }

    let rareIndices: Set<Int> = [0, meetingCount / 2]

    // Populate inside a `do` block so `writeStore` is deallocated before
    // cold measurements -- avoids a live SQLite connection to the same file.
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

    var tierResults = try await measureQueries(queries, storeDir: dir)
    try await tierResults.append(measureFetchFaultTier(storeDir: dir))

    return TierReport(
        meetingCount: meetingCount,
        wordsPerMeeting: segCount * wordsPerSeg,
        populateMs: populateMs,
        results: tierResults
    )
}

/// Measures cold/warm latency for each query against a pre-populated on-disk store.
private func measureQueries(
    _ queries: [(label: String, query: String)], storeDir: URL
) async throws -> [QueryResult] {
    var results: [QueryResult] = []
    for (label, query) in queries {
        let coldStore = try DataStore(storage: .onDisk(storeDir))
        let cold = try await measureSearch(store: coldStore, query: query)

        var warmValues: [Double] = []
        var hitCount = 0
        for _ in 0 ..< warmRuns {
            let result = try await measureSearch(store: coldStore, query: query)
            warmValues.append(result.millis)
            hitCount = result.hitCount
        }

        results.append(QueryResult(
            label: label, coldMs: cold.millis,
            warmMedianMs: median(warmValues),
            warmSpread: spreadStr(warmValues), hitCount: hitCount
        ))
    }
    return results
}

/// Measures cold/warm fetch+fault (no scoring) against a pre-populated store.
private func measureFetchFaultTier(storeDir: URL) async throws -> QueryResult {
    let coldStore = try DataStore(storage: .onDisk(storeDir))
    let fetchCold = try await measureFetchFault(store: coldStore)
    var fetchWarmValues: [Double] = []
    for _ in 0 ..< warmRuns {
        try await fetchWarmValues.append(measureFetchFault(store: coldStore))
    }
    return QueryResult(
        label: "fetch+fault (no scoring)", coldMs: fetchCold,
        warmMedianMs: median(fetchWarmValues),
        warmSpread: spreadStr(fetchWarmValues), hitCount: -1
    )
}

/// Measures search latency at 50 / 500 / 5000 meetings with ~5000 words each.
/// Excluded from `make test` and `make ci`. Run via `make bench`.
@Suite("Search benchmark full (BISCOTTI_RUN_BENCH=1)",
       .enabled(if: isBenchEnabled), .serialized)
struct SearchBenchmarkFullTests {
    @Test("Search latency at 50 / 500 / 5000 meetings",
          .timeLimit(.minutes(30)))
    func benchmark() async throws {
        var allTiers: [TierReport] = []
        for tierCount in [50, 500, 5000] {
            try await allTiers.append(runTier(meetingCount: tierCount))
        }
        printReport(tiers: allTiers)
    }
}
