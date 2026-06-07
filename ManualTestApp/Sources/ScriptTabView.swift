import ManualTestKit
import SwiftUI

/// Root view: one tab per test script from ManualTestKit's `allScripts` registry.
struct ScriptTabView: View {
    private let wiredScripts: [TestScript]
    private let resultsStore: ResultsStore

    init() {
        let store = ResultsStore(fileURL: Self.resultsFileURL())
        resultsStore = store
        wiredScripts = WiredScripts.all()
    }

    var body: some View {
        TabView {
            ForEach(wiredScripts) { script in
                ScriptRunnerView(script: script, store: resultsStore)
                    .tabItem {
                        Text(script.title)
                    }
                    .tag(script.id)
            }
        }
        .padding()
    }

    /// Returns the path to the results JSON file.
    ///
    /// Resolution order:
    /// 1. `MANUAL_TEST_RESULTS_PATH` environment variable (absolute path).
    /// 2. Repo-relative `ManualTestApp/Results/manual_test_results.json` resolved via
    ///    Xcode's `SRCROOT` build setting (the ManualTestApp project root).
    /// 3. Fallback: `~/Documents/ManualTestApp/manual_test_results.json`.
    ///
    /// During normal development builds (Xcode or `xcodebuild`), option 2 resolves to the
    /// checked-in results file so the app reads/writes the same file the CI gate checks.
    /// After running, commit the updated file so the gate turns green.
    private static func resultsFileURL() -> URL {
        if let envPath = ProcessInfo.processInfo.environment["MANUAL_TEST_RESULTS_PATH"] {
            return URL(fileURLWithPath: envPath)
        }
        // SRCROOT is set by Xcode/xcodebuild to the project directory (ManualTestApp/).
        if let srcRoot = ProcessInfo.processInfo.environment["SRCROOT"] {
            return URL(fileURLWithPath: srcRoot)
                .appendingPathComponent("Results", isDirectory: true)
                .appendingPathComponent("manual_test_results.json")
        }
        // Fallback for ad-hoc launches outside Xcode.
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
        let dir = docs.appendingPathComponent("ManualTestApp", isDirectory: true)
        return dir.appendingPathComponent("manual_test_results.json")
    }
}
