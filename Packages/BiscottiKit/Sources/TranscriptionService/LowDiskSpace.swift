import Foundation

/// The free space on the disk that holds the compiled speech models
/// (`~/Library/Caches`, on the startup disk).
///
/// macOS deletes those compiled models when the disk runs low, and the
/// next load compiles again for minutes. The level is not public; on the
/// Mac measured on 25 October 2026 it purged with about 14.8 GB as its goal,
/// so less than 20 GB counts as low.
public struct DiskSpace: Sendable {
    /// Below this, macOS may remove the compiled speech models.
    public static let lowThreshold: Int64 = 20_000_000_000

    /// The bytes available for important use, nil when unknown. This count
    /// includes purgeable space, the compiled models among it, so a disk
    /// with much purgeable data reads as roomy while macOS purges it, and no
    /// low-disk message shows then. The query can block, so it is read off
    /// the main actor.
    public let availableBytes: @Sendable () -> Int64?

    public init(availableBytes: @escaping @Sendable () -> Int64?) {
        self.availableBytes = availableBytes
    }

    /// Reads the volume of the user's Caches folder.
    public static let system = DiskSpace {
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
        let values = try? caches?.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
        return values?.volumeAvailableCapacityForImportantUsage
    }

    /// True below `lowThreshold`; false when the space is unknown.
    public var isLow: Bool {
        availableBytes().map { $0 < Self.lowThreshold } ?? false
    }
}

/// When a slow model load is the disk's fault: the load compiled the model
/// again, and the disk is low.
public enum SlowModelLoad {
    /// Loads from the compiled cache took 0.3 s (whisper-small) and 1 s
    /// (large-v3); compiles took about 2 and 4 minutes. A load this long
    /// compiled.
    public static let compileThreshold: Duration = .seconds(15)

    /// The final transcription's status while a slow load is the disk's fault.
    public static let finalPassStatus = "Taking longer: your Mac is low on disk space"
}
