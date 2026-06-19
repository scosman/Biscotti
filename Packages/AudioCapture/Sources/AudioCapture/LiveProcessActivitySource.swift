import CoreAudio
import Foundation
import os
import Synchronization

private let logger = Logger(subsystem: "net.scosman.biscotti.audiocapture", category: "ProcessActivity")

/// Live process-activity source using Core Audio property listeners.
///
/// Registers a system-level `kAudioHardwarePropertyProcessObjectList` listener
/// and per-process `kAudioProcessPropertyIsRunning`, `IsRunningInput`, and
/// `IsRunningOutput` listeners. All fires yield into a single
/// `AsyncStream<Void>` so the monitor can re-snapshot.
///
/// Per-process listeners are reconciled whenever the process list changes.
/// All listeners are removed on stream termination.
final class LiveProcessActivitySource: ProcessActivitySource, @unchecked Sendable {
    func currentProcesses() -> [AudioProcess] {
        CoreAudioHelpers.allAudioProcesses()
    }

    func processChanges() -> AsyncStream<Void> {
        AsyncStream { continuation in
            let listenerQueue = DispatchQueue(
                label: "net.scosman.biscotti.process-activity",
                qos: .userInitiated
            )

            // Mutable state for per-process listeners, protected by Mutex
            // for Sendable closure capture. Each process has multiple
            // listeners (IsRunning, IsRunningInput, IsRunningOutput).
            let processListeners = Mutex<[AudioObjectID: [CoreAudioHelpers.ProcessPropertyListener]]>([:])

            // Reconcile per-process listeners against the current process list.
            let reconcile: @Sendable () -> Void = {
                Self.reconcileListeners(
                    processListeners: processListeners,
                    queue: listenerQueue,
                    continuation: continuation
                )
            }

            // Register the system process list listener.
            let systemListener = CoreAudioHelpers.addProcessListListener(queue: listenerQueue) {
                logger.debug("Process list changed — reconciling")
                reconcile()
            }

            guard let systemListener else {
                logger.error("Failed to register process list listener — stream will be empty")
                continuation.finish()
                return
            }

            // Initial reconcile to register per-process listeners for existing processes.
            listenerQueue.async {
                reconcile()
            }

            // Cleanup on termination.
            continuation.onTermination = { @Sendable _ in
                processListeners.withLock { listeners in
                    for (_, perProcessListeners) in listeners {
                        for listener in perProcessListeners {
                            CoreAudioHelpers.removeProcessPropertyListener(listener)
                        }
                    }
                    listeners.removeAll()
                }
                CoreAudioHelpers.removeProcessListListener(systemListener)
            }
        }
    }

    /// Properties to monitor per process. `IsRunning` fires on any IO
    /// toggle; `IsRunningInput`/`IsRunningOutput` fire specifically when
    /// mic or speaker usage changes (needed because a process already
    /// doing output won't flip `IsRunning` when mic-only toggles).
    private static let monitoredProperties: [AudioObjectPropertySelector] = [
        kAudioProcessPropertyIsRunning,
        kAudioProcessPropertyIsRunningInput,
        kAudioProcessPropertyIsRunningOutput
    ]

    /// Reconciles per-process property listeners against the current
    /// system process list. Adds listeners for new processes, removes
    /// all listeners for departed ones, then yields into the
    /// continuation so the monitor re-snapshots.
    private static func reconcileListeners(
        processListeners: borrowing Mutex<[AudioObjectID: [CoreAudioHelpers.ProcessPropertyListener]]>,
        queue: DispatchQueue,
        continuation: AsyncStream<Void>.Continuation
    ) {
        let currentIDs = Set(
            CoreAudioHelpers.getPropertyArray(
                objectID: AudioObjectID(kAudioObjectSystemObject),
                address: AudioObjectPropertyAddress(
                    mSelector: kAudioHardwarePropertyProcessObjectList,
                    mScope: kAudioObjectPropertyScopeGlobal,
                    mElement: kAudioObjectPropertyElementMain
                ),
                type: AudioObjectID.self
            )
        )

        processListeners.withLock { listeners in
            let trackedIDs = Set(listeners.keys)

            // Remove departed — remove ALL listeners for each process
            for removedID in trackedIDs.subtracting(currentIDs) {
                if let removed = listeners.removeValue(forKey: removedID) {
                    for listener in removed {
                        CoreAudioHelpers.removeProcessPropertyListener(listener)
                    }
                }
            }

            // Add new — register a listener for each monitored property
            for newID in currentIDs.subtracting(trackedIDs) {
                var registered: [CoreAudioHelpers.ProcessPropertyListener] = []
                for property in monitoredProperties {
                    if let listener = CoreAudioHelpers.addProcessPropertyListener(
                        processID: newID,
                        property: property,
                        queue: queue,
                        handler: {
                            logger.debug("Process \(newID) running state changed")
                            continuation.yield()
                        }
                    ) {
                        registered.append(listener)
                    }
                }
                if !registered.isEmpty {
                    listeners[newID] = registered
                }
            }
        }

        // Intentional trailing yield: triggers a re-snapshot in the monitor
        // after listener reconciliation. Per-process listeners above also yield
        // on state changes, so a newly-added process that fires immediately may
        // cause a double-emit — this is harmless because the monitor dedups via
        // snapshot comparison and suppresses unchanged emissions.
        continuation.yield()
    }
}
