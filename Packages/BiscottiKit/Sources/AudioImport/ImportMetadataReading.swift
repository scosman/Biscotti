import AVFoundation
import Foundation

/// Seam for reading a file's meeting date.
public protocol ImportMetadataReading: Sendable {
    /// Embedded media creation date, else file modification date, else nil.
    func meetingDate(for source: URL) async -> Date?
}

/// Live implementation using AVFoundation metadata and file attributes.
public struct AVFoundationMetadataReader: ImportMetadataReading {
    public init() {}

    public func meetingDate(for source: URL) async -> Date? {
        let asset = AVURLAsset(url: source)

        // 1. Try asset.creationDate.
        if let item = try? await asset.load(.creationDate),
           let date = try? await item.load(.dateValue)
        {
            return date
        }

        // 2. Try common metadata.
        if let metadata = try? await asset.load(.metadata) {
            for item in metadata {
                if item.commonKey == .commonKeyCreationDate,
                   let date = try? await item.load(.dateValue)
                {
                    return date
                }
            }
        }

        // 3. File modification date.
        if let values = try? source.resourceValues(
            forKeys: [.contentModificationDateKey]
        ) {
            return values.contentModificationDate
        }

        return nil
    }
}
