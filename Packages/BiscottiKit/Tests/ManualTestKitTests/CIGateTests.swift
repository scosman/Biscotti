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
}
