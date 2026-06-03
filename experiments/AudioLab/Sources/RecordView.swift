import CoreAudio
import SwiftUI

struct RecordView: View {
    @State private var coordinator = RecordingCoordinator()
    @State private var monitor = AudioStreamMonitor()
    @State private var captureMode: CaptureMode = .global
    @State private var selectedProcessID: AudioObjectID?

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Recording")
                .font(.title2)
                .fontWeight(.semibold)

            GroupBox("Capture Mode") {
                VStack(alignment: .leading, spacing: 10) {
                    Picker("System Audio", selection: $captureMode) {
                        ForEach(CaptureMode.allCases) { mode in
                            Text(mode.rawValue).tag(mode)
                        }
                    }
                    .pickerStyle(.segmented)
                    .disabled(coordinator.isRecording)

                    if captureMode == .perProcess {
                        processSelector
                    }
                }
                .padding(.vertical, 4)
            }

            HStack(spacing: 16) {
                Button(action: toggleRecording) {
                    Label(
                        coordinator.isRecording ? "Stop Recording" : "Start Recording",
                        systemImage: coordinator.isRecording ? "stop.circle.fill" : "record.circle"
                    )
                    .font(.title3)
                }
                .buttonStyle(.borderedProminent)
                .tint(coordinator.isRecording ? .red : .accentColor)

                if coordinator.isRecording {
                    RecordingTimerView(coordinator: coordinator)
                }
            }

            if let error = coordinator.lastError {
                GroupBox {
                    Label(error, systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.red)
                }
            }

            if coordinator.micFileURL != nil || coordinator.systemFileURL != nil {
                fileInfoSection
            }

            Spacer()
        }
        .padding()
        .onAppear {
            monitor.startMonitoring()
        }
        .onDisappear {
            monitor.stopMonitoring()
        }
    }

    @ViewBuilder
    private var processSelector: some View {
        let outputProcesses = monitor.activeOutputProcesses
        if outputProcesses.isEmpty {
            Text("No processes currently producing audio output.")
                .foregroundStyle(.secondary)
                .font(.caption)
        } else {
            Picker("Target App", selection: $selectedProcessID) {
                Text("Select an app...").tag(nil as AudioObjectID?)
                ForEach(outputProcesses) { process in
                    Text("\(process.displayName) (PID \(process.pid))")
                        .tag(process.id as AudioObjectID?)
                }
            }
            .disabled(coordinator.isRecording)
        }
    }

    @ViewBuilder
    private var fileInfoSection: some View {
        if coordinator.isRecording {
            TimelineView(.periodic(from: .now, by: 0.5)) { _ in
                GroupBox("Files") {
                    fileInfoContent
                }
            }
        } else {
            GroupBox("Files") {
                fileInfoContent
            }
        }
    }

    @ViewBuilder
    private var fileInfoContent: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let url = coordinator.micFileURL {
                FileInfoRow(
                    label: "Microphone",
                    url: url,
                    size: coordinator.micFileSize
                )
            }
            if let url = coordinator.systemFileURL {
                FileInfoRow(
                    label: "System Audio",
                    url: url,
                    size: coordinator.systemFileSize
                )
            }
            if coordinator.isRecording {
                Text("Duration: \(formattedDuration(coordinator.elapsedTime))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 4)
    }

    private func toggleRecording() {
        if coordinator.isRecording {
            coordinator.stopRecording()
        } else {
            let targetID: AudioObjectID? =
                captureMode == .perProcess ? selectedProcessID : nil
            coordinator.startRecording(captureMode: captureMode, targetProcessID: targetID)
        }
    }

    private func formattedDuration(_ seconds: TimeInterval) -> String {
        let hrs = Int(seconds) / 3600
        let mins = (Int(seconds) % 3600) / 60
        let secs = Int(seconds) % 60
        if hrs > 0 {
            return String(format: "%d:%02d:%02d", hrs, mins, secs)
        }
        return String(format: "%02d:%02d", mins, secs)
    }
}

struct RecordingTimerView: View {
    let coordinator: RecordingCoordinator

    var body: some View {
        TimelineView(.periodic(from: .now, by: 0.5)) { _ in
            HStack(spacing: 4) {
                Circle()
                    .fill(.red)
                    .frame(width: 10, height: 10)
                Text(formattedDuration(coordinator.elapsedTime))
                    .font(.system(.title3, design: .monospaced))
                    .foregroundStyle(.red)
            }
        }
    }

    private func formattedDuration(_ seconds: TimeInterval) -> String {
        let hrs = Int(seconds) / 3600
        let mins = (Int(seconds) % 3600) / 60
        let secs = Int(seconds) % 60
        if hrs > 0 {
            return String(format: "%d:%02d:%02d", hrs, mins, secs)
        }
        return String(format: "%02d:%02d", mins, secs)
    }
}

struct FileInfoRow: View {
    let label: String
    let url: URL
    let size: Int64

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
            HStack {
                Text(url.lastPathComponent)
                    .font(.system(.caption, design: .monospaced))
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer()
                Text(RecordingFileManager.formattedSize(size))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }
}
