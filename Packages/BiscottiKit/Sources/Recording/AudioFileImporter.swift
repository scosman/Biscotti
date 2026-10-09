import AVFoundation
import Foundation

// MARK: - Errors

/// Why importing an existing audio file failed. Every case carries a
/// user-facing description via `LocalizedError`.
public enum AudioImportError: Error, Equatable, Sendable, LocalizedError {
    /// The file is missing, is not a regular file, or AVFoundation could not open it.
    case unreadable
    /// The file opened but contains no audio track.
    case noAudioTrack
    /// The file is zero bytes or its audio duration is zero.
    case emptyAudio
    /// Copying the file into Biscotti's storage failed.
    case copyFailed(String)
    /// Creating or updating the meeting record failed.
    case storageFailed(String)

    public var errorDescription: String? {
        switch self {
        case .unreadable:
            "Biscotti couldn't read this file. It may be damaged, or it isn't an audio file."
        case .noAudioTrack:
            "This file doesn't contain an audio track."
        case .emptyAudio:
            "This file is empty or has no audio to transcribe."
        case let .copyFailed(detail):
            "Biscotti couldn't copy the file into its library. \(detail)"
        case let .storageFailed(detail):
            "Biscotti couldn't save the imported meeting. \(detail)"
        }
    }
}

// MARK: - Value types

/// The result of validating a candidate audio file.
public struct ValidatedAudio: Sendable, Equatable {
    /// Audio duration in seconds (always > 0).
    public let duration: TimeInterval
    /// File creation date, falling back to modification date, then now.
    public let startDate: Date
    /// Source file size in bytes (always > 0).
    public let byteSize: Int64
}

/// A file copied into a meeting directory.
public struct StagedAudio: Sendable, Equatable {
    public let url: URL
    public let byteSize: Int64
}

// MARK: - Importer

/// File-handling half of "transcribe an existing audio file". Pure
/// validation + on-disk staging, with no knowledge of the store. All members
/// are safe to call off the main actor (and should be: they do file I/O and
/// AVFoundation work).
public struct AudioFileImporter: Sendable {
    public typealias CopyFile = @Sendable (_ source: URL, _ destination: URL) throws -> Void

    /// Base name of the copied file; the original extension is appended.
    public static let importedBaseName = "imported"

    private let copyFile: CopyFile

    /// - Parameter copyFile: The copy primitive. Injectable so tests can
    ///   simulate a mid-copy failure.
    public init(
        copyFile: @escaping CopyFile = { source, destination in
            try FileManager.default.copyItem(at: source, to: destination)
        }
    ) {
        self.copyFile = copyFile
    }

    /// Checks that `url` is a readable file with a non-empty audio track.
    /// Creates nothing on disk.
    public func validate(_ url: URL) async throws(AudioImportError) -> ValidatedAudio {
        let keys: Set<URLResourceKey> = [
            .isRegularFileKey, .fileSizeKey, .creationDateKey, .contentModificationDateKey
        ]
        let values: URLResourceValues
        do {
            values = try url.resourceValues(forKeys: keys)
        } catch {
            throw .unreadable
        }
        guard values.isRegularFile == true, FileManager.default.isReadableFile(atPath: url.path) else {
            throw .unreadable
        }
        let byteSize = Int64(values.fileSize ?? 0)
        guard byteSize > 0 else { throw .emptyAudio }

        let asset = AVURLAsset(url: url)
        let duration: CMTime
        let tracks: [AVAssetTrack]
        do {
            duration = try await asset.load(.duration)
            tracks = try await asset.loadTracks(withMediaType: .audio)
        } catch {
            throw .unreadable
        }
        guard !tracks.isEmpty else { throw .noAudioTrack }
        let seconds = duration.seconds
        guard seconds.isFinite, seconds > 0 else { throw .emptyAudio }

        return ValidatedAudio(
            duration: seconds,
            startDate: values.creationDate ?? values.contentModificationDate ?? Date(),
            byteSize: byteSize
        )
    }

    /// Creates `directory`, writes the `.recording` marker first (so a crash
    /// mid-copy is reconciled by orphan recovery), then copies `source` in as
    /// `imported.<original extension>`.
    public func stage(source: URL, into directory: URL) throws(AudioImportError) -> StagedAudio {
        let fileManager = FileManager.default
        let ext = source.pathExtension
        let name = ext.isEmpty ? Self.importedBaseName : "\(Self.importedBaseName).\(ext)"
        let destination = directory.appendingPathComponent(name)
        do {
            try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
            let marker = directory.appendingPathComponent(RecordingController.markerFileName)
            guard fileManager.createFile(atPath: marker.path, contents: nil) else {
                throw CocoaError(.fileWriteUnknown)
            }
            try copyFile(source, destination)
            let attrs = try fileManager.attributesOfItem(atPath: destination.path)
            let size = (attrs[.size] as? Int64) ?? 0
            return StagedAudio(url: destination, byteSize: size)
        } catch {
            throw .copyFailed(error.localizedDescription)
        }
    }

    /// Removes the `.recording` marker once the meeting is fully set up.
    public func finalize(directory: URL) {
        let marker = directory.appendingPathComponent(RecordingController.markerFileName)
        try? FileManager.default.removeItem(at: marker)
    }

    /// Best-effort removal of a partially staged meeting directory.
    public func discard(directory: URL) {
        try? FileManager.default.removeItem(at: directory)
    }
}
