import Foundation
import ManualTestKit

// A tiny CLI that checks the manual-test results file for unrun steps.
// Used by `make manual-tests-check` and CI to enforce the manual-test gate.
//
// Usage: manual-tests-check <path-to-results.json>
// Exit 0 if every known step has been run (pass or fail).
// Exit 1 if any step is not-run or missing from the file.

guard CommandLine.arguments.count == 2 else {
    fputs("Usage: manual-tests-check <path-to-results.json>\n", stderr)
    exit(2)
}

let path = CommandLine.arguments[1]
let url = URL(fileURLWithPath: path)
let store = ResultsStore(fileURL: url)

do {
    let unrunIDs = try store.unrun(in: allScripts)
    if unrunIDs.isEmpty {
        print("All \(store.recordableStepIDs(in: allScripts).count) manual test steps have been run.")
        exit(0)
    } else {
        print("\(unrunIDs.count) manual test step(s) not yet run:")
        for id in unrunIDs {
            print("  - \(id)")
        }
        exit(1)
    }
} catch {
    fputs("Error reading results file: \(error)\n", stderr)
    exit(2)
}
