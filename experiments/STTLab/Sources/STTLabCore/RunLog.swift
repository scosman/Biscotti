import Foundation

/// Timestamped line logger. Appends to a file and optionally echoes to an observer.
/// Thread-safe: all writes are serialized through a lock.
public final class RunLog: @unchecked Sendable {
    private let fileHandle: FileHandle?
    private let logURL: URL?
    private let observer: (@Sendable (String) -> Void)?
    private let echoToStdout: Bool
    private let lock = NSLock()
    private let dateFormatter: DateFormatter

    /// Create a RunLog.
    /// - Parameters:
    ///   - logURL: File to append to. Created if it does not exist.
    ///   - echoToStdout: Also print each line to stdout (default true for CLI use).
    ///   - observer: Optional closure called with each formatted line.
    public init(logURL: URL? = nil, echoToStdout: Bool = true,
                observer: (@Sendable (String) -> Void)? = nil)
    {
        self.logURL = logURL
        self.echoToStdout = echoToStdout
        self.observer = observer

        dateFormatter = DateFormatter()
        dateFormatter.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS"
        dateFormatter.locale = Locale(identifier: "en_US_POSIX")
        dateFormatter.timeZone = TimeZone.current

        if let logURL {
            let dir = logURL.deletingLastPathComponent()
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            if !FileManager.default.fileExists(atPath: logURL.path) {
                FileManager.default.createFile(atPath: logURL.path, contents: nil)
            }
            fileHandle = FileHandle(forWritingAtPath: logURL.path)
            fileHandle?.seekToEndOfFile()
        } else {
            fileHandle = nil
        }
    }

    deinit {
        try? fileHandle?.close()
    }

    /// Log a timestamped line.
    public func log(_ message: String) {
        lock.lock()
        defer { lock.unlock() }

        let timestamp = dateFormatter.string(from: Date())
        let line = "[\(timestamp)] \(message)\n"

        if let data = line.data(using: .utf8) {
            fileHandle?.write(data)
        }

        if echoToStdout {
            print("[\(timestamp)] \(message)")
        }

        observer?(line)
    }
}
