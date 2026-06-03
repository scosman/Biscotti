import SwiftUI

struct StreamsView: View {
    @State private var monitor = AudioStreamMonitor()

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Audio Processes")
                    .font(.title2)
                    .fontWeight(.semibold)
                Spacer()
                Button("Refresh") {
                    monitor.refresh()
                }
                Text("\(monitor.processes.count) processes")
                    .foregroundStyle(.secondary)
            }

            if monitor.processes.isEmpty {
                ContentUnavailableView(
                    "No Audio Processes",
                    systemImage: "speaker.slash",
                    description: Text("No processes are currently using the audio system.")
                )
            } else {
                Table(monitor.processes) {
                    TableColumn("App") { process in
                        HStack(spacing: 6) {
                            if process.isMeetingApp {
                                Image(systemName: "video.fill")
                                    .foregroundStyle(.blue)
                                    .help("Known meeting app")
                            }
                            Text(process.displayName)
                                .fontWeight(process.isMeetingApp ? .medium : .regular)
                        }
                    }
                    .width(min: 140, ideal: 200)

                    TableColumn("Bundle ID") { process in
                        Text(process.bundleID)
                            .font(.system(.body, design: .monospaced))
                            .foregroundStyle(.secondary)
                    }
                    .width(min: 180, ideal: 260)

                    TableColumn("PID") { process in
                        Text("\(process.pid)")
                            .font(.system(.body, design: .monospaced))
                    }
                    .width(min: 50, ideal: 60)

                    TableColumn("Input") { process in
                        StatusDot(isActive: process.isRunningInput, label: "Mic")
                    }
                    .width(min: 50, ideal: 60)

                    TableColumn("Output") { process in
                        StatusDot(isActive: process.isRunningOutput, label: "Speaker")
                    }
                    .width(min: 50, ideal: 60)
                }
            }
        }
        .padding()
        .onAppear {
            monitor.startMonitoring()
        }
        .onDisappear {
            monitor.stopMonitoring()
        }
    }
}

struct StatusDot: View {
    let isActive: Bool
    let label: String

    var body: some View {
        HStack(spacing: 4) {
            Circle()
                .fill(isActive ? Color.green : Color.gray.opacity(0.3))
                .frame(width: 8, height: 8)
            Text(isActive ? "Active" : "Idle")
                .font(.caption)
                .foregroundStyle(isActive ? .primary : .secondary)
        }
        .help(label)
    }
}
