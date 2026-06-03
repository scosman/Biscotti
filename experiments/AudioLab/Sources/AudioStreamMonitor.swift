import CoreAudio
import Foundation
import Observation

@Observable
@MainActor
final class AudioStreamMonitor {
    private(set) var processes: [AudioProcess] = []
    private var listener: CoreAudioHelpers.ProcessListListener?
    private let pollQueue = DispatchQueue(label: "com.steak.audiolab.stream-monitor")
    private var isMonitoring = false

    func startMonitoring() {
        guard !isMonitoring else { return }
        isMonitoring = true
        refresh()

        listener = CoreAudioHelpers.addProcessListListener(queue: pollQueue) { [weak self] in
            Task { @MainActor in
                self?.refresh()
            }
        }
    }

    func stopMonitoring() {
        isMonitoring = false
        if let listener {
            CoreAudioHelpers.removeProcessListListener(listener)
            self.listener = nil
        }
    }

    func refresh() {
        processes = CoreAudioHelpers.allAudioProcesses()
    }

    var meetingApps: [AudioProcess] {
        processes.filter { $0.isMeetingApp }
    }

    var activeOutputProcesses: [AudioProcess] {
        processes.filter { $0.isRunningOutput }
    }
}
