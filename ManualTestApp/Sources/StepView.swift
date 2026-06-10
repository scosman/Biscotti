import Combine
import ManualTestKit
import SwiftUI

/// Holds the latest status message for a running `.action` step so the view can
/// show a caption. Mutated on the main actor from the action's `status`
/// callback (which may be invoked off the main thread, e.g. from the XPC
/// status channel).
@MainActor
final class StepStatusModel: ObservableObject {
    @Published var message: String?
}

/// Renders a single `TestStep` with interaction controls and a status badge.
struct StepView: View {
    let step: TestStep
    let result: TestResult?
    let onResult: (TestResult) -> Void

    @State private var isRunning = false
    @State private var errorMessage: String?
    @State private var checkOutcome: CheckOutcome?
    @State private var noteText = ""
    @StateObject private var statusModel = StepStatusModel()

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            statusBadge
                .frame(width: 24)

            VStack(alignment: .leading, spacing: 8) {
                switch step {
                case let .action(id, label, run):
                    actionView(id: id, label: label, run: run)

                case let .instruction(_, text):
                    instructionView(text: text)

                case let .humanQuestion(id, prompt):
                    humanQuestionView(id: id, prompt: prompt)

                case let .autoCheck(id, label, check):
                    autoCheckView(id: id, label: label, check: check)
                }
            }
        }
    }

    // MARK: - Step type views

    @ViewBuilder
    private func actionView(
        id: String,
        label: String,
        run: @escaping @Sendable (@escaping @Sendable (String) -> Void) async throws -> Void
    ) -> some View {
        Text(label).font(.headline)

        HStack(spacing: 8) {
            Button("Run") {
                Task { await executeAction(id: id, run: run) }
            }
            .disabled(isRunning)

            if isRunning {
                ProgressView()
                    .controlSize(.small)
            }
        }

        if isRunning, let message = statusModel.message {
            Text(message)
                .foregroundStyle(.secondary)
                .font(.caption)
        }

        if let errorMessage {
            Text(errorMessage)
                .foregroundStyle(.red)
                .font(.caption)
        }
    }

    private func instructionView(text: String) -> some View {
        Label(text, systemImage: "info.circle")
            .font(.body)
            .foregroundStyle(.secondary)
    }

    @ViewBuilder
    private func humanQuestionView(id: String, prompt: String) -> some View {
        Text(prompt).font(.headline)

        TextField("Optional note", text: $noteText)
            .textFieldStyle(.roundedBorder)
            .frame(maxWidth: 400)

        HStack(spacing: 12) {
            Button("Yes (Pass)") {
                recordHuman(id: id, status: .pass)
            }
            Button("No (Fail)") {
                recordHuman(id: id, status: .fail)
            }
        }
    }

    @ViewBuilder
    private func autoCheckView(
        id: String,
        label: String,
        check: @escaping @Sendable () async -> CheckOutcome
    ) -> some View {
        Text(label).font(.headline)

        HStack(spacing: 8) {
            Button("Run Check") {
                Task { await executeCheck(id: id, check: check) }
            }
            .disabled(isRunning)

            if isRunning {
                ProgressView()
                    .controlSize(.small)
            }
        }

        if let checkOutcome {
            Text(checkOutcome.detail)
                .foregroundStyle(checkOutcome.passed ? .green : .red)
                .font(.caption)
        }
    }

    // MARK: - Status badge

    @ViewBuilder
    private var statusBadge: some View {
        switch result?.status {
        case .pass:
            Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(.green)
        case .fail:
            Image(systemName: "xmark.circle.fill")
                .foregroundStyle(.red)
        case .notRun, nil:
            Image(systemName: "circle")
                .foregroundStyle(.secondary)
        }
    }

    // MARK: - Actions

    @MainActor
    private func executeAction(
        id: String,
        run: @escaping @Sendable (@escaping @Sendable (String) -> Void) async throws -> Void
    ) async {
        isRunning = true
        errorMessage = nil
        statusModel.message = nil

        // The status callback may fire off the main thread (the model-download
        // status arrives over XPC), so hop to the main actor to update state.
        let model = statusModel
        let report: @Sendable (String) -> Void = { message in
            Task { @MainActor in model.message = message }
        }

        do {
            try await run(report)
            onResult(TestResult(stepID: id, status: .pass, timestamp: .now))
        } catch {
            errorMessage = error.localizedDescription
            onResult(TestResult(stepID: id, status: .fail, note: error.localizedDescription, timestamp: .now))
        }
        statusModel.message = nil
        isRunning = false
    }

    private func executeCheck(
        id: String,
        check: @escaping @Sendable () async -> CheckOutcome
    ) async {
        isRunning = true
        let outcome = await check()
        checkOutcome = outcome
        let status: TestStatus = outcome.passed ? .pass : .fail
        onResult(TestResult(stepID: id, status: status, note: outcome.detail, timestamp: .now))
        isRunning = false
    }

    private func recordHuman(id: String, status: TestStatus) {
        let note = noteText.isEmpty ? nil : noteText
        onResult(TestResult(stepID: id, status: status, note: note, timestamp: .now))
    }
}
