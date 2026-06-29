import Foundation

/// Describes a disk-space shortfall for a model download.
/// Drives the click-time "Not Enough Disk Space" alert on both
/// Settings and Onboarding surfaces.
public struct DiskWarning: Equatable, Sendable {
    public let modelName: String
    public let requiredBytes: Int64
    public let availableBytes: Int64

    public init(
        modelName: String,
        requiredBytes: Int64,
        availableBytes: Int64
    ) {
        self.modelName = modelName
        self.requiredBytes = requiredBytes
        self.availableBytes = availableBytes
    }

    /// Alert body copy for the "Not Enough Disk Space" modal.
    /// Shared across Settings and Onboarding surfaces.
    public var alertMessage: String {
        let required = ModelDiskPolicy.formatBytes(requiredBytes)
        let available = ModelDiskPolicy.formatBytes(availableBytes)
        return "\"\(modelName)\" needs about \(required) of free space to download, but only \(available) is free. Free up some space and try again."
    }
}

/// Shared disk-space policy for model downloads.
///
/// The click-time check replaces the old proactive inline warnings.
/// Both LLM and transcription download surfaces use the same rule:
/// free space must exceed the download size + a generous 2 GB buffer.
public enum ModelDiskPolicy {
    /// Generous round buffer beyond the raw download size.
    /// Covers temp/extraction overhead and absorbs a concurrently-started
    /// transcription download (which is < 2 GB).
    public static let downloadBufferBytes: Int64 = 2_000_000_000

    /// Returns a `DiskWarning` when free space is insufficient, else nil.
    ///
    /// When `freeBytes` is nil (capacity read failed) the check returns nil
    /// -- never falsely block a download on a failed capacity read.
    public static func warning(
        modelName: String,
        downloadBytes: Int64,
        freeBytes: Int64?
    ) -> DiskWarning? {
        guard let freeBytes else { return nil }
        let required = downloadBytes + downloadBufferBytes
        guard freeBytes < required else { return nil }
        return DiskWarning(
            modelName: modelName,
            requiredBytes: required,
            availableBytes: freeBytes
        )
    }

    /// Human-readable "~N GB" / "~N.N GB" formatting for alert copy.
    public static func formatBytes(_ bytes: Int64) -> String {
        let gigabytes = Double(bytes) / 1_000_000_000
        if gigabytes == gigabytes.rounded() {
            return "~\(Int(gigabytes)) GB"
        }
        return String(format: "~%.1f GB", gigabytes)
    }
}
