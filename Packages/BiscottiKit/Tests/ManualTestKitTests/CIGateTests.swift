import Foundation
import ManualTestKit
import Testing

@Suite("CI gate logic via ResultsStore.unrun")
struct CIGateTests {
    /// Returns a store backed by a unique temp file.
    private func makeStore() -> ResultsStore {
        let dir = FileManager.default.temporaryDirectory
        let file = dir.appendingPathComponent("ci_gate_\(UUID().uuidString).json")
        return ResultsStore(fileURL: file)
    }

    /// A minimal script for testing purposes.
    private static let tinyScript = TestScript(
        id: "tiny",
        title: "Tiny Script",
        steps: [
            .instruction(id: "t1", text: "Step one"),
            .instruction(id: "t2", text: "Step two"),
            .instruction(id: "t3", text: "Step three")
        ]
    )

    @Test("All steps unrun when results file is empty")
    func allUnrunWhenEmpty() throws {
        let store = makeStore()
        let unrun = try store.unrun(in: [CIGateTests.tinyScript])
        #expect(unrun.count == 3)
        #expect(unrun.contains("t1"))
        #expect(unrun.contains("t2"))
        #expect(unrun.contains("t3"))
    }

    @Test("All-pass results report zero unrun (gate passes)")
    func allPassGatePasses() throws {
        let store = makeStore()
        try store.record(TestResult(stepID: "t1", status: .pass))
        try store.record(TestResult(stepID: "t2", status: .pass))
        try store.record(TestResult(stepID: "t3", status: .pass))

        let unrun = try store.unrun(in: [CIGateTests.tinyScript])
        #expect(unrun.isEmpty)
    }

    @Test("One not-run result makes the gate report failure")
    func oneNotRunFails() throws {
        let store = makeStore()
        try store.record(TestResult(stepID: "t1", status: .pass))
        try store.record(TestResult(stepID: "t2", status: .notRun))
        try store.record(TestResult(stepID: "t3", status: .pass))

        let unrun = try store.unrun(in: [CIGateTests.tinyScript])
        #expect(unrun == ["t2"])
    }

    @Test("Missing entry counts as unrun")
    func missingEntryIsUnrun() throws {
        let store = makeStore()
        try store.record(TestResult(stepID: "t1", status: .pass))
        // t2 and t3 never recorded

        let unrun = try store.unrun(in: [CIGateTests.tinyScript])
        #expect(unrun.count == 2)
        #expect(unrun.contains("t2"))
        #expect(unrun.contains("t3"))
    }

    @Test("Fail status does NOT count as unrun (test was executed)")
    func failIsNotUnrun() throws {
        let store = makeStore()
        try store.record(TestResult(stepID: "t1", status: .fail))
        try store.record(TestResult(stepID: "t2", status: .pass))
        try store.record(TestResult(stepID: "t3", status: .pass))

        let unrun = try store.unrun(in: [CIGateTests.tinyScript])
        #expect(unrun.isEmpty)
    }

    @Test("allStepIDs collects IDs from multiple scripts")
    func allStepIDsMultipleScripts() {
        let store = makeStore()
        let secondScript = TestScript(
            id: "extra",
            title: "Extra",
            steps: [.instruction(id: "e1", text: "Extra step")]
        )
        let ids = store.allStepIDs(in: [CIGateTests.tinyScript, secondScript])
        #expect(ids == ["t1", "t2", "t3", "e1"])
    }

    // MARK: - Seed file integration

    /// Resolves the repo-root path from the test source file's location.
    /// The test file lives at Packages/BiscottiKit/Tests/ManualTestKitTests/ — five
    /// levels below the repo root.
    private static func repoRoot() -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent() // ManualTestKitTests/
            .deletingLastPathComponent() // Tests/
            .deletingLastPathComponent() // BiscottiKit/
            .deletingLastPathComponent() // Packages/
            .deletingLastPathComponent() // repo root
    }

    @Test("Results file parses and covers every canonical step ID")
    func resultsFileCoversAllStepIDs() throws {
        let resultsURL = CIGateTests.repoRoot()
            .appendingPathComponent("ManualTestApp")
            .appendingPathComponent("Results")
            .appendingPathComponent("manual_test_results.json")

        // Verify the file exists so this test fails clearly if it's moved.
        #expect(
            FileManager.default.fileExists(atPath: resultsURL.path),
            "Results file not found at \(resultsURL.path)"
        )

        let store = ResultsStore(fileURL: resultsURL)
        // Must parse as a valid results dictionary.
        let results = try store.load()
        let allIDs = store.allStepIDs(in: allScripts)

        // Every canonical step ID must have an entry (any status). This catches
        // script/results drift WITHOUT constraining the human-recorded status:
        // this file is the live Phase 4.5 results store (populated on real
        // hardware), not a pristine seed, so saved pass/fail results must coexist
        // with a green `make test`. The non-gating `manual-tests-check` is what
        // tracks whether every step has actually been run.
        #expect(allIDs.count == 20, "Expected 20 total step IDs (16 audio + 4 transcription)")
        for id in allIDs {
            #expect(results[id] != nil, "Results file is missing an entry for step '\(id)'")
        }
    }
}
