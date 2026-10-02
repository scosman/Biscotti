import ArgumentParser
import DataStore
import Foundation

/// Shared logic for resolving the `--store` path and opening a DataStore.
enum StoreLocation {
    /// The default store directory: `~/Library/Application Support/Biscotti`.
    static let defaultPath: String = {
        guard let appSupport = FileManager.default.urls(
            for: .applicationSupportDirectory, in: .userDomainMask
        ).first else {
            return NSString("~/Library/Application Support/Biscotti").expandingTildeInPath
        }
        return appSupport.appendingPathComponent("Biscotti").path
    }()

    /// True when `path` (nil = default) resolves to the app's own store directory.
    static func isDefault(_ path: String?) -> Bool {
        guard let path else { return true }
        let given = URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
            .standardizedFileURL.resolvingSymlinksInPath()
        let standard = URL(fileURLWithPath: defaultPath)
            .standardizedFileURL.resolvingSymlinksInPath()
        return given.path == standard.path
    }

    /// Resolves the store path, validates that `Biscotti.store` exists, and
    /// opens a `DataStore`.
    ///
    /// Prints a message to stderr and throws `ExitCode.failure` when the store
    /// file is missing (never creates an empty store).
    static func open(path: String?, writer: StandardOutputWriter) throws -> DataStore {
        let resolved = (path ?? defaultPath) as NSString
        let expanded = resolved.expandingTildeInPath
        let storeURL = URL(fileURLWithPath: expanded)
        let storeFile = storeURL.appendingPathComponent("Biscotti.store")

        guard FileManager.default.fileExists(atPath: storeFile.path) else {
            writer.writeStderr("Error: Biscotti.store not found at \(expanded)")
            writer.writeStderr("Use --store to specify the directory that contains Biscotti.store.")
            throw ExitCode.failure
        }

        writer.writeStderr("Store: \(expanded)")
        return try DataStore(storage: .onDisk(storeURL))
    }
}
