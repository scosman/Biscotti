import CoreAudio
import Foundation
import Observation

@Observable
@MainActor
final class AudioStreamMonitor {
    private(set) var processes: [AudioProcess] = []
    private var listener: CoreAudioHelpers.ProcessListListener?
    private var processListeners: [AudioObjectID: CoreAudioHelpers.ProcessPropertyListener] = [:]
    private let listenerQueue = DispatchQueue(label: "com.steak.audiolab.stream-monitor")
    private var isMonitoring = false

    func startMonitoring() {
        guard !isMonitoring else { return }
        isMonitoring = true
        refresh()

        listener = CoreAudioHelpers.addProcessListListener(queue: listenerQueue) { [weak self] in
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
        removeAllProcessListeners()
    }

    /// Re-reads the full process list and reconciles per-process I/O listeners
    /// (adding listeners for new processes, removing them for departed ones).
    func refresh() {
        processes = CoreAudioHelpers.allAudioProcesses()
        reconcileProcessListeners()
    }

    var meetingApps: [AudioProcess] {
        processes.filter { $0.isMeetingApp }
    }

    var activeOutputProcesses: [AudioProcess] {
        processes.filter { $0.isRunningOutput }
    }

    // MARK: - Per-Process Listener Management

    // We listen on kAudioProcessPropertyIsRunning (not the IsRunningInput/
    // IsRunningOutput variants) because a macOS bug prevents those from
    // posting notifications. kAudioProcessPropertyIsRunning fires reliably
    // on overall I/O start/stop; on each fire we re-read the input/output
    // state to update the dots.
    //
    // Limitation: kAudioProcessPropertyIsRunning only transitions on the
    // overall boolean (no-IO → IO, IO → no-IO). It does NOT fire when a
    // process that is already running output starts or stops input (e.g.
    // mic mute/unmute mid-call while speaker audio continues). Those
    // changes require a manual Refresh until Apple fixes the per-property
    // notifications.
    //
    // See: https://developer.apple.com/forums/thread/825780

    // Listener add/remove (AudioObjectAddPropertyListenerBlock) is done
    // synchronously on @MainActor. These are microsecond HAL registration
    // calls, not data reads. Keeping them synchronous eliminates TOCTOU
    // races where concurrent reconciles could double-register listeners.
    // The genuinely-slow part — AudioObjectGetPropertyData reads in the
    // listener callback — runs on listenerQueue, off the main thread.

    private func reconcileProcessListeners() {
        let currentIDs = Set(processes.map(\.id))
        let trackedIDs = Set(processListeners.keys)

        let idsToRemove = trackedIDs.subtracting(currentIDs)
        let idsToAdd = currentIDs.subtracting(trackedIDs)

        // Remove listeners for departed processes
        for removedID in idsToRemove {
            if let listener = processListeners.removeValue(forKey: removedID) {
                CoreAudioHelpers.removeProcessPropertyListener(listener)
            }
        }

        // Add one kAudioProcessPropertyIsRunning listener per new process.
        // The handler fires on listenerQueue, reads I/O state there (off
        // main thread), then hops to @MainActor to apply the result.
        let queue = listenerQueue
        for newID in idsToAdd {
            let handler: @Sendable () -> Void = { [weak self] in
                let state = CoreAudioHelpers.processIOState(for: newID)
                Task { @MainActor in
                    self?.applyProcessIOState(newID, state: state)
                }
            }
            if let listener = CoreAudioHelpers.addProcessPropertyListener(
                processID: newID,
                property: kAudioProcessPropertyIsRunning,
                queue: queue,
                handler: handler
            ) {
                processListeners[newID] = listener
            }
        }
    }

    /// Applies a pre-read I/O state to the processes array. Must be called on @MainActor.
    private func applyProcessIOState(
        _ processID: AudioObjectID,
        state: (isRunningInput: Bool, isRunningOutput: Bool)
    ) {
        guard let index = processes.firstIndex(where: { $0.id == processID }) else { return }
        let existing = processes[index]
        if existing.isRunningInput != state.isRunningInput || existing.isRunningOutput != state.isRunningOutput {
            processes[index] = AudioProcess(
                id: existing.id,
                bundleID: existing.bundleID,
                pid: existing.pid,
                isRunningInput: state.isRunningInput,
                isRunningOutput: state.isRunningOutput
            )
        }
    }

    private func removeAllProcessListeners() {
        for (_, listener) in processListeners {
            CoreAudioHelpers.removeProcessPropertyListener(listener)
        }
        processListeners.removeAll()
    }
}
