import Foundation

/// A validated bundle ready for processing.
public struct LoadedBundle: Sendable {
    public let manifest: BundleManifest
    public let metas: [MeetingMeta]
    public let bundleURL: URL

    public init(manifest: BundleManifest, metas: [MeetingMeta], bundleURL: URL) {
        self.manifest = manifest
        self.metas = metas
        self.bundleURL = bundleURL
    }
}

/// Errors from bundle validation.
public enum BundleLoaderError: Error, Equatable {
    case manifestNotFound(URL)
    case bundleVersionMismatch(found: Int, expected: Int)
    case metaNotFound(meetingID: String)
    case audioNotFound(meetingID: String, path: String)
}

/// Loads and validates a bundle folder. Pure Foundation; no model or framework dependencies.
public enum BundleLoader {
    /// Load the manifest and all meeting metadata, and check that audio files exist.
    /// - Parameter bundleURL: The path to the bundle folder (containing manifest.json).
    /// - Returns: A validated `LoadedBundle`.
    public static func load(from bundleURL: URL) throws -> LoadedBundle {
        let manifestURL = bundleURL.appendingPathComponent("manifest.json")
        guard FileManager.default.fileExists(atPath: manifestURL.path) else {
            throw BundleLoaderError.manifestNotFound(manifestURL)
        }

        let manifest: BundleManifest = try JSONFiles.read(from: manifestURL)

        guard manifest.schemaVersion == SchemaVersions.bundle else {
            throw BundleLoaderError.bundleVersionMismatch(
                found: manifest.schemaVersion,
                expected: SchemaVersions.bundle
            )
        }

        var metas: [MeetingMeta] = []
        for mid in manifest.meetings {
            let meetingDir = bundleURL.appendingPathComponent("meetings/\(mid)")
            let metaURL = meetingDir.appendingPathComponent("meta.json")
            guard FileManager.default.fileExists(atPath: metaURL.path) else {
                throw BundleLoaderError.metaNotFound(meetingID: mid)
            }
            let meta: MeetingMeta = try JSONFiles.read(from: metaURL)

            let audioURL = meetingDir.appendingPathComponent(meta.audioFile)
            guard FileManager.default.fileExists(atPath: audioURL.path) else {
                throw BundleLoaderError.audioNotFound(meetingID: mid, path: audioURL.path)
            }

            metas.append(meta)
        }

        return LoadedBundle(manifest: manifest, metas: metas, bundleURL: bundleURL)
    }
}
