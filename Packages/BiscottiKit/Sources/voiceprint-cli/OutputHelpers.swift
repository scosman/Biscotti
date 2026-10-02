import AppKit
import ArgumentParser
import Foundation

// MARK: - Output writer

/// Writes CLI output: results to stdout, progress/messages to stderr.
struct StandardOutputWriter {
    func writeStdout(_ text: String) {
        FileHandle.standardOutput.write(Data((text + "\n").utf8))
    }

    func writeStderr(_ text: String) {
        FileHandle.standardError.write(Data((text + "\n").utf8))
    }
}

// MARK: - App running guard

enum AppRunningGuard {
    private static let biscottiBundleID = "net.scosman.biscotti"

    /// Checks whether the Biscotti app is running. If so, prints a message
    /// to stderr and throws `ExitCode(2)`.
    ///
    /// Only the app's own store needs the guard. A `--store` that points to a
    /// different directory (for example a copy) is safe while the app runs.
    @MainActor
    static func check(storePath: String?, writer: StandardOutputWriter) throws {
        guard StoreLocation.isDefault(storePath) else { return }
        let running = NSWorkspace.shared.runningApplications.contains {
            $0.bundleIdentifier == biscottiBundleID
        }
        if running {
            writer.writeStderr(
                "Error: Quit Biscotti first. Opening the database can migrate it, "
                    + "and two processes must not do that at the same time."
            )
            throw ExitCode(2)
        }
    }
}
