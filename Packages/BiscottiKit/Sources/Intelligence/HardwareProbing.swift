import Foundation

/// Abstracts hardware queries (RAM, free disk) so suitability logic is
/// fully unit-testable with fake values. Only two reads are needed --
/// physical RAM and free disk space on a given volume.
public protocol HardwareProbing: Sendable {
    /// Total physical RAM in bytes.
    var physicalMemoryBytes: UInt64 { get }

    /// Free disk space in bytes on the volume containing `url`, or `nil`
    /// if the capacity could not be determined.
    func availableDiskBytes(at url: URL) -> Int64?
}

/// Production probe: reads real hardware via Foundation APIs.
public struct LiveHardwareProbe: HardwareProbing {
    public init() {}

    public var physicalMemoryBytes: UInt64 {
        ProcessInfo.processInfo.physicalMemory
    }

    public func availableDiskBytes(at url: URL) -> Int64? {
        let values = try? url.resourceValues(
            forKeys: [.volumeAvailableCapacityForImportantUsageKey]
        )
        return values?.volumeAvailableCapacityForImportantUsage
    }
}
