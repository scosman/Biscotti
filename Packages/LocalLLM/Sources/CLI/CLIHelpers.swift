import ArgumentParser
import Foundation
import LocalLLM

/// The resolved default model file path for CLI commands.
///
/// Composed from ``LocalLLMPaths.defaultModelCacheDir`` + the default model URL's filename.
let defaultModelFilePath: URL =
    LocalLLMPaths.defaultModelCacheDir.appendingPathComponent(ModelDownloader.defaultModelURL.lastPathComponent)

/// Write a diagnostic message to stderr (with trailing newline).
func logStderr(_ message: String) {
    FileHandle.standardError.write(Data((message + "\n").utf8))
}

/// Read a file from a path string, expanding tildes. Throws a clear error on failure.
func readFile(path: String, label: String) throws -> String {
    let expanded = (path as NSString).expandingTildeInPath
    let url = URL(fileURLWithPath: expanded)
    do {
        return try String(contentsOf: url, encoding: .utf8)
    } catch {
        throw ValidationError("Cannot read \(label) at \(expanded): \(error.localizedDescription)")
    }
}
