import Foundation

enum RecordingFileManager {
    static let micSuffix = "_mic.aac"
    static let systemSuffix = "_system.aac"

    static func recordingsDirectory() -> URL {
        let documentsURL = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
        let recordingsURL = documentsURL.appendingPathComponent("AudioLab", isDirectory: true)
        try? FileManager.default.createDirectory(at: recordingsURL, withIntermediateDirectories: true)
        return recordingsURL
    }

    static func generateTimestamp() -> String {
        let formatter = DateFormatter()
        // yyyyMMdd'T'HHmmss produces e.g. "20260603T143000" -- unambiguous,
        // filesystem-safe, and trivially reversible. The timezone offset is
        // omitted since local time is sufficient for file naming.
        formatter.dateFormat = "yyyyMMdd'T'HHmmss"
        formatter.timeZone = .current
        return formatter.string(from: Date())
    }

    static func filePaths(timestamp: String) -> (mic: URL, system: URL) {
        let dir = recordingsDirectory()
        let mic = dir.appendingPathComponent(timestamp + micSuffix)
        let system = dir.appendingPathComponent(timestamp + systemSuffix)
        return (mic, system)
    }

    static func fileSize(at url: URL) -> Int64 {
        (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int64) ?? 0
    }

    static func formattedSize(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }
}
