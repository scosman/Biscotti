import ManualTestKit
import SwiftUI

/// Renders a single test script as a scrollable list of steps, each with its status badge.
struct ScriptRunnerView: View {
    let script: TestScript
    let store: ResultsStore

    @State private var results: [String: TestResult] = [:]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text(script.title)
                    .font(.title)
                    .padding(.bottom, 4)

                ForEach(script.steps) { step in
                    StepView(
                        step: step,
                        result: results[step.id],
                        onResult: { result in
                            recordResult(result)
                        }
                    )
                    Divider()
                }
            }
            .padding()
        }
        .onAppear { loadResults() }
    }

    private func loadResults() {
        do {
            results = try store.load()
        } catch {
            results = [:]
        }
    }

    private func recordResult(_ result: TestResult) {
        results[result.stepID] = result
        do {
            try store.record(result)
        } catch {
            // Best-effort persistence; the in-memory map is still updated.
        }
    }
}
