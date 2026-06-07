import CoreAudio
import Foundation
import os
import Synchronization

private let logger = Logger(subsystem: "net.scosman.biscotti.audiocapture", category: "ProcessActivity")

/// Live process-activity source using Core Audio property listeners.
///
/// Registers a system-level `kAudioHardwarePropertyProcessObjectList` listener
/// and per-process `kAudioProcessPropertyIsRunning` listeners. All fires yield
/// into a single `AsyncStream<Void>` so the monitor can re-snapshot.
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
            // for Sendable closure capture.
            let processListeners = Mutex<[AudioObjectID: CoreAudioHelpers.ProcessPropertyListener]>([:])

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
                    for (_, listener) in listeners {
                        CoreAudioHelpers.removeProcessPropertyListener(listener)
                    }
                    listeners.removeAll()
                }
                CoreAudioHelpers.removeProcessListListener(systemListener)
            }
        }
    }

    /// Reconciles per-process `kAudioProcessPropertyIsRunning` listeners
    /// against the current system process list. Adds listeners for new
    /// processes, removes listeners for departed ones, then yields into
    /// the continuation so the monitor re-snapshots.
    private static func reconcileListeners(
        processListeners: borrowing Mutex<[AudioObjectID: CoreAudioHelpers.ProcessPropertyListener]>,
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

            // Remove departed
            for removedID in trackedIDs.subtracting(currentIDs) {
                if let listener = listeners.removeValue(forKey: removedID) {
                    CoreAudioHelpers.removeProcessPropertyListener(listener)
                }
            }

            // Add new
            for newID in currentIDs.subtracting(trackedIDs) {
                if let listener = CoreAudioHelpers.addProcessPropertyListener(
                    processID: newID,
                    property: kAudioProcessPropertyIsRunning,
                    queue: queue,
                    handler: {
                        logger.debug("Process \(newID) running state changed")
                        continuation.yield()
                    }
                ) {
                    listeners[newID] = listener
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
