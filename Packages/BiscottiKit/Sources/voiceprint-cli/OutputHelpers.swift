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
    @MainActor
    static func check(writer: StandardOutputWriter) throws {
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
