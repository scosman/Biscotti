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

    /// A minimal script for testing purposes. Uses recordable (`.humanQuestion`)
    /// steps so the gate-mechanics tests below exercise steps that the gate
    /// actually tracks — instruction steps are never gated (see
    /// `instructionStepsAreNeverGated`).
    private static let tinyScript = TestScript(
        id: "tiny",
        title: "Tiny Script",
        steps: [
            .humanQuestion(id: "t1", prompt: "Step one?"),
            .humanQuestion(id: "t2", prompt: "Step two?"),
            .humanQuestion(id: "t3", prompt: "Step three?")
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

    @Test("allStepIDs collects every ID, including instructions")
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

    @Test("recordableStepIDs and the gate exclude instruction steps")
    func instructionStepsAreNeverGated() throws {
        let store = makeStore()
        let mixed = TestScript(
            id: "mixed",
            title: "Mixed",
            steps: [
                .instruction(id: "i1", text: "Do some setup"),
                .humanQuestion(id: "q1", prompt: "Did it work?")
            ]
        )

        // The instruction is not part of the recordable set...
        #expect(store.recordableStepIDs(in: [mixed]) == ["q1"])

        // ...so with an empty results file only the recordable step is unrun;
        // the instruction never appears even though it has no entry.
        let unrun = try store.unrun(in: [mixed])
        #expect(unrun == ["q1"])
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
        let recordableIDs = store.recordableStepIDs(in: allScripts)

        // Every *recordable* step ID must have an entry (any status). Instruction
        // steps are display-only and never written to the file, so they are
        // excluded here. This catches script/results drift WITHOUT constraining
        // the human-recorded status: this file is the live Phase 4.5 results
        // store (populated on real hardware), not a pristine seed, so saved
        // pass/fail results must coexist with a green `make test`. The non-gating
        // `manual-tests-check` is what tracks whether every step has actually run.
        #expect(
            recordableIDs.count == 32,
            "Expected 32 recordable step IDs (13 audio + 4 transcription + 15 LLM)"
        )
        for id in recordableIDs {
            #expect(results[id] != nil, "Results file is missing an entry for step '\(id)'")
        }

        // Non-recordable (instruction) steps must NOT be written to the file.
        let instructionIDs = Set(store.allStepIDs(in: allScripts))
            .subtracting(recordableIDs)
        for id in instructionIDs {
            #expect(results[id] == nil, "Instruction step '\(id)' should not be in the results file")
        }
    }
}
