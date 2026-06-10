import Foundation
import ManualTestKit
import Testing

@Suite("ResultsStore persistence and CI-gate logic")
struct ResultsStoreTests {
    /// Returns a store backed by a temp file that doesn't exist yet.
    private func makeStore() -> ResultsStore {
        let dir = FileManager.default.temporaryDirectory
        let file = dir.appendingPathComponent("test_results_\(UUID().uuidString).json")
        return ResultsStore(fileURL: file)
    }

    @Test("Load returns empty dictionary when file does not exist")
    func loadEmpty() throws {
        let store = makeStore()
        let results = try store.load()
        #expect(results.isEmpty)
    }

    @Test("Record writes and load round-trips a result")
    func recordAndLoad() throws {
        let store = makeStore()
        let result = TestResult(stepID: "step_1", status: .pass, note: "looks good")
        try store.record(result)

        let loaded = try store.load()
        #expect(loaded.count == 1)
        #expect(loaded["step_1"]?.status == .pass)
        #expect(loaded["step_1"]?.note == "looks good")
    }

    @Test("Record overwrites existing entry for the same step ID")
    func recordOverwrites() throws {
        let store = makeStore()
        try store.record(TestResult(stepID: "s1", status: .pass))
        try store.record(TestResult(stepID: "s1", status: .fail, note: "broke"))

        let loaded = try store.load()
        #expect(loaded.count == 1)
        #expect(loaded["s1"]?.status == .fail)
        #expect(loaded["s1"]?.note == "broke")
    }

    @Test("Multiple records accumulate distinct step IDs")
    func multipleRecords() throws {
        let store = makeStore()
        try store.record(TestResult(stepID: "a", status: .pass))
        try store.record(TestResult(stepID: "b", status: .fail))
        try store.record(TestResult(stepID: "c", status: .notRun))

        let loaded = try store.load()
        #expect(loaded.count == 3)
        #expect(loaded["a"]?.status == .pass)
        #expect(loaded["b"]?.status == .fail)
        #expect(loaded["c"]?.status == .notRun)
    }

    @Test("markScriptNotRun resets all supplied step IDs to not-run")
    func markScriptNotRun() throws {
        let store = makeStore()
        try store.record(TestResult(stepID: "x1", status: .pass))
        try store.record(TestResult(stepID: "x2", status: .pass))
        try store.record(TestResult(stepID: "other", status: .pass))

        try store.markScriptNotRun(scriptID: "script_x", allStepIDs: ["x1", "x2"])

        let loaded = try store.load()
        #expect(loaded["x1"]?.status == .notRun)
        #expect(loaded["x2"]?.status == .notRun)
        // "other" should be untouched
        #expect(loaded["other"]?.status == .pass)
    }

    @Test("Load returns empty dictionary for a zero-byte file")
    func loadZeroByte() throws {
        let store = makeStore()
        // Create an empty file on disk (zero bytes).
        FileManager.default.createFile(atPath: store.fileURL.path, contents: Data())
        let results = try store.load()
        #expect(results.isEmpty)
    }

    @Test("Timestamp round-trips through JSON")
    func timestampRoundTrip() throws {
        let store = makeStore()
        let now = Date()
        try store.record(TestResult(stepID: "t", status: .pass, timestamp: now))

        let loaded = try store.load()
        let loadedDate = try #require(loaded["t"]?.timestamp)
        // ISO8601 encodes to whole seconds, so allow a 1-second tolerance.
        #expect(abs(loadedDate.timeIntervalSince(now)) < 1.0)
    }
}
