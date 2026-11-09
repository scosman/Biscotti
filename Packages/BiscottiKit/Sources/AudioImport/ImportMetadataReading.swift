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
        await Task.detached(priority: .utility) {
            readDate(for: source)
        }.value
    }

    private func readDate(for source: URL) -> Date? {
        let asset = AVURLAsset(url: source)

        // 1. Try asset.creationDate (blocking from detached task).
        let semaphore = DispatchSemaphore(value: 0)
        var creationDate: Date?
        Task {
            if let item = try? await asset.load(.creationDate),
               let date = try? await item.load(.dateValue)
            {
                creationDate = date
            } else if let metadata = try? await asset.load(.metadata) {
                for item in metadata {
                    if item.commonKey == .commonKeyCreationDate,
                       let date = try? await item.load(.dateValue)
                    {
                        creationDate = date
                        break
                    }
                }
            }
            semaphore.signal()
        }
        semaphore.wait()

        if let creationDate {
            return creationDate
        }

        // 2. File modification date.
        if let values = try? source.resourceValues(
            forKeys: [.contentModificationDateKey]
        ) {
            return values.contentModificationDate
        }

        return nil
    }
}
