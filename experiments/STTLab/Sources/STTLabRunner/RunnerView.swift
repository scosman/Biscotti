import SwiftUI

/// The single window of the STTLabRunner app.
struct RunnerView: View {
    @State private var model = RunnerModel()

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            headerSection
            Divider()
            bundleSection
            if !model.meetingRows.isEmpty {
                meetingTable
                controlsSection
                progressSection
            }
            Divider()
            logSection
        }
        .padding()
        .frame(minWidth: 720, minHeight: 560)
    }

    // MARK: - Sections

    private var headerSection: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("STTLab Runner")
                .font(.title)
                .fontWeight(.bold)
            Text(model.systemInfoText)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var bundleSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Button("Choose Bundle...") {
                    model.chooseBundle()
                }
                .disabled(model.isRunning)

                if model.bundleURL != nil {
                    Button("Change...") {
                        model.chooseBundle()
                    }
                    .disabled(model.isRunning)
                }

                Spacer()
            }

            if !model.bundleInfo.isEmpty {
                Text(model.bundleInfo)
                    .font(.callout)
            }

            if let resultsURL = model.resultsURL {
                Text("Results: \(resultsURL.path)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
        }
    }

    private var meetingTable: some View {
        Table(model.meetingRows) {
            TableColumn("Meeting") { row in
                Text(row.id)
                    .font(.body.monospaced())
            }
            .width(min: 60, ideal: 80)

            TableColumn("Duration") { row in
                Text(formatDuration(row.durationSeconds))
            }
            .width(min: 60, ideal: 80)

            TableColumn("Locale") { row in
                Text(row.locale)
            }
            .width(min: 60, ideal: 80)

            TableColumn("Status") { row in
                statusView(row.status)
            }
            .width(min: 120, ideal: 200)
        }
        .frame(minHeight: 150, maxHeight: 250)
    }

    private var controlsSection: some View {
        HStack(spacing: 12) {
            Button(model.isRunning ? "Running..." : "Run") {
                model.startRun()
            }
            .disabled(model.isRunning || model.bundleURL == nil || !model.speechAvailable)
            .keyboardShortcut(.return)

            Toggle("Re-run all (force)", isOn: $model.forceRerun)
                .disabled(model.isRunning)

            if model.isRunning {
                Button("Stop after current meeting") {
                    model.stopAfterCurrent()
                }
            }

            Spacer()

            if !model.isRunning, model.resultsURL != nil {
                Button("Reveal Results in Finder") {
                    model.revealResults()
                }
            }
        }
    }

    private var progressSection: some View {
        VStack(alignment: .leading, spacing: 4) {
            if !model.progressText.isEmpty {
                Text(model.progressText)
                    .font(.callout)
            }
            ProgressView(value: model.overallProgress)
        }
    }

    private var logSection: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Log")
                .font(.caption)
                .foregroundStyle(.secondary)
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 1) {
                        ForEach(Array(model.logLines.enumerated()), id: \.offset) { index, line in
                            Text(line)
                                .font(.system(.caption, design: .monospaced))
                                .textSelection(.enabled)
                                .id(index)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .onChange(of: model.logLines.count) { _, newCount in
                    if newCount > 0 {
                        proxy.scrollTo(newCount - 1, anchor: .bottom)
                    }
                }
            }
            .frame(minHeight: 100, maxHeight: 200)
            .background(Color(nsColor: .textBackgroundColor))
            .clipShape(RoundedRectangle(cornerRadius: 4))
        }
    }

    // MARK: - Helpers

    @ViewBuilder
    private func statusView(_ status: MeetingStatus) -> some View {
        switch status {
        case .pending:
            Text("pending")
                .foregroundStyle(.secondary)
        case let .running(percent):
            HStack(spacing: 4) {
                ProgressView()
                    .controlSize(.small)
                Text("running \(percent)%")
            }
        case .completed:
            Label("completed", systemImage: "checkmark.circle.fill")
                .foregroundStyle(.green)
        case .skipped:
            Text("skipped (done)")
                .foregroundStyle(.secondary)
        case let .failed(msg):
            Label("failed", systemImage: "xmark.circle.fill")
                .foregroundStyle(.red)
                .help(msg)
        case .unsupportedLocale:
            Text("unsupported locale")
                .foregroundStyle(.orange)
        }
    }

    private func formatDuration(_ seconds: Double) -> String {
        let mins = Int(seconds) / 60
        let secs = Int(seconds) % 60
        return String(format: "%d:%02d", mins, secs)
    }
}
