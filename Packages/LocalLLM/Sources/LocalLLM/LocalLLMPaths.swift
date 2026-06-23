import Foundation

/// Shared path constants for the LocalLLM library and CLI.
///
/// The model cache lives at `~/Library/Application Support/Biscotti/llms` so the
/// large GGUF file is never duplicated between the CLI and the app.
public enum LocalLLMPaths {
    /// The shared model cache directory.
    public static let defaultModelCacheDir: URL = {
        let home = FileManager.default.homeDirectoryForCurrentUser
        return home.appendingPathComponent("Library/Application Support/Biscotti/llms")
    }()
}
