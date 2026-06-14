import ArgumentParser
import Foundation
import LocalLLM

/// The shared model cache directory used by the CLI and (eventually) the Biscotti app.
///
/// This is `~/Library/Application Support/Biscotti/llms` -- a single location so the
/// large GGUF file is never duplicated between the CLI experiment and the app.
let defaultCacheDirectory: URL = {
    let home = FileManager.default.homeDirectoryForCurrentUser
    return home.appendingPathComponent("Library/Application Support/Biscotti/llms")
}()

/// The resolved default model file path for CLI commands.
///
/// Composed from ``defaultCacheDirectory`` + the default model URL's filename.
let defaultModelFilePath: URL =
    defaultCacheDirectory.appendingPathComponent(ModelDownloader.defaultModelURL.lastPathComponent)

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
