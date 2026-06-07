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

    /// Returns the path to the results JSON file inside the app's documents directory.
    private static func resultsFileURL() -> URL {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
        let dir = docs.appendingPathComponent("ManualTestApp", isDirectory: true)
        return dir.appendingPathComponent("results.json")
    }
}
