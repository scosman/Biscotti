import Darwin
import Foundation
import os

/// Returns free heap pages to the kernel to shrink the process's resident
/// footprint after a large transient allocation is released.
///
/// Biscotti lives in the menu bar ~99% of the time; the UI window and an
/// active recording are the two big memory spikes, and both should fully
/// recover when they end. `malloc` holds freed pages in per-zone caches
/// rather than handing them straight back to the OS, so resident memory
/// stays high even once the views/audio buffers are deallocated.
/// `malloc_zone_pressure_relief(nil, 0)` walks every zone and scavenges as
/// much of that cache back to the kernel as it can.
///
/// We schedule the scavenge on a short delay so SwiftUI/AppKit have
/// finished tearing the views down (and audio buffers have drained) before
/// we ask malloc to reclaim — otherwise the pages aren't free yet.
public enum MemoryPressure {
    private static let logger = Logger(
        subsystem: "net.scosman.biscotti",
        category: "memory"
    )

    /// Schedules a malloc pressure-relief pass `delay` seconds from now.
    ///
    /// - Parameters:
    ///   - delay: Seconds to wait before scavenging, giving the triggering
    ///     teardown time to actually free its allocations.
    ///   - reason: Short label for the log line (e.g. `"window-close"`).
    public static func relieve(after delay: TimeInterval, reason: String) {
        // Hop to a utility queue: the scavenge can briefly block, and there
        // is no reason to do it on the main thread.
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + delay) {
            let reclaimed = malloc_zone_pressure_relief(nil, 0)
            logger.debug(
                "pressure relief (\(reason, privacy: .public)): reclaimed \(reclaimed) bytes"
            )
        }
    }
}
