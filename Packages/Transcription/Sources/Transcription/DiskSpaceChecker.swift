import Foundation

/// Checks available disk space and throws if insufficient.
///
/// Behind a protocol so tests can inject a fake checker without touching the filesystem.
protocol DiskSpaceChecking: Sendable {
    func checkAvailableSpace(requiredBytes: Int64) throws
}

/// Production disk-space checker that queries the system volume.
struct SystemDiskSpaceChecker: DiskSpaceChecking {
    func checkAvailableSpace(requiredBytes: Int64) throws {
        let homeURL = FileManager.default.homeDirectoryForCurrentUser
        let values = try homeURL.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
        let available = values.volumeAvailableCapacityForImportantUsage ?? 0
        guard available >= requiredBytes else {
            throw TranscriptionError.insufficientDisk(
                requiredBytes: requiredBytes,
                availableBytes: Int64(available)
            )
        }
    }
}
