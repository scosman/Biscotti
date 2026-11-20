import AppCore
import Automation
import DesignSystem
import SwiftUI

/// The microphone priority list.
///
/// Biscotti records from the first connected entry; the system default is
/// always the last resort. Reordering uses up/down buttons rather than drag,
/// which works reliably inside a grouped `Form` on macOS.
struct MicrophonePrioritySection: View {
    let core: AppCore
    @State private var connected: [MicCandidate] = []

    private var store: AutomationSettingsStore {
        core.automation
    }

    private var entries: [MicPriorityEntry] {
        store.settings.micPriority
    }

    var body: some View {
        Section("Microphone") {
            caption("Biscotti records from the first connected microphone in this list. Teams and Zoom choose their microphone separately; set them to \u{201C}Default\u{201D} to keep them in step with macOS.")
            ForEach(Array(entries.enumerated()), id: \.element.id) { index, entry in
                entryRow(entry, index: index)
            }
            systemDefaultRow
            HStack {
                addMenu
                Spacer()
                Button("Refresh Devices") { refresh() }
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            VStack(alignment: .leading, spacing: Tokens.spacingXS) {
                Toggle("Switch to a higher-priority microphone that connects during a recording", isOn: switchUpBinding)
                caption("Switching leaves a gap of about a second. Off: stay on the starting microphone while it is connected.")
            }
            if let last = core.lastMicrophoneName {
                caption("Most recent recording used: \(last)")
            }
        }
        .onAppear { refresh() }
    }

    // MARK: - Rows

    private func entryRow(_ entry: MicPriorityEntry, index: Int) -> some View {
        HStack {
            Text("\(index + 1).").monospacedDigit().foregroundStyle(Tokens.secondaryText)
            Text(entry.title)
            status(for: entry)
            Spacer()
            Button { move(index, by: -1) } label: { Image(systemName: "chevron.up") }
                .disabled(index == 0)
                .help("Move up")
            Button { move(index, by: 1) } label: { Image(systemName: "chevron.down") }
                .disabled(index == entries.count - 1)
                .help("Move down")
            Button { remove(index) } label: { Image(systemName: "minus.circle") }
                .help("Remove")
        }
        .buttonStyle(.borderless)
    }

    private var systemDefaultRow: some View {
        HStack {
            Text("\(entries.count + 1).").monospacedDigit().foregroundStyle(Tokens.secondaryText)
            Text("System default")
            if let current = connected.first(where: \.isSystemDefault) {
                caption("(now \(current.name))")
            }
            Spacer()
            caption("Always last")
        }
    }

    @ViewBuilder
    private func status(for entry: MicPriorityEntry) -> some View {
        switch entry {
        case let .device(uid, _):
            let isConnected = connected.contains { $0.uid == uid }
            Image(systemName: isConnected ? "circle.fill" : "circle")
                .font(.caption2)
                .foregroundStyle(isConnected ? Color.green : Tokens.secondaryText)
                .help(isConnected ? "Connected" : "Not connected")
        case .anyHeadset, .anyBluetooth, .anyUSB:
            if let uid = MicChooser.choose(priority: [entry], connected: connected),
               let match = connected.first(where: { $0.uid == uid })
            {
                caption("(now \(match.name))")
            } else {
                caption("(none connected)")
            }
        }
    }

    private var addMenu: some View {
        Menu("Add Microphone") {
            ForEach(MicPriorityEntry.groups.filter { !entries.contains($0) }) { group in
                Button(group.title) { add(group) }
            }
            Divider()
            let available = connected.filter { candidate in
                !entries.contains { $0.id == MicPriorityEntry.device(uid: candidate.uid, name: candidate.name).id }
            }
            if available.isEmpty {
                Text("All connected microphones are in the list")
            }
            ForEach(available) { candidate in
                Button(candidate.name) { add(.device(uid: candidate.uid, name: candidate.name)) }
            }
        }
        .fixedSize()
    }

    // MARK: - Actions

    private func refresh() {
        connected = core.connectedMicrophones()
    }

    private func add(_ entry: MicPriorityEntry) {
        store.update { $0.micPriority.append(entry) }
    }

    private func remove(_ index: Int) {
        store.update { settings in
            guard settings.micPriority.indices.contains(index) else { return }
            settings.micPriority.remove(at: index)
        }
    }

    private func move(_ index: Int, by offset: Int) {
        store.update { settings in
            let target = index + offset
            guard settings.micPriority.indices.contains(index),
                  settings.micPriority.indices.contains(target)
            else { return }
            settings.micPriority.swapAt(index, target)
        }
    }

    private var switchUpBinding: Binding<Bool> {
        Binding(
            get: { store.settings.micSwitchUp },
            set: { value in store.update { $0.micSwitchUp = value } }
        )
    }

    private func caption(_ text: String) -> some View {
        Text(text)
            .font(Tokens.metadataFont)
            .foregroundStyle(Tokens.secondaryText)
    }
}
