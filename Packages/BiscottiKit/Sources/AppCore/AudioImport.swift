import AVFoundation
import Foundation
import UniformTypeIdentifiers

// MARK: - Probe result

/// What we learned about a user-chosen audio file before importing it.
public struct AudioImportInfo: Sendable, Equatable {
    /// Length of the audio in seconds (always > 0).
    public let duration: TimeInterval
    /// The date to show for the meeting: the file's own date, not import time.
    /// See ``AudioImporter/effectiveDate(creation:modification:now:)``.
    public let date: Date

    public init(duration: TimeInterval, date: Date) {
        self.duration = duration
        self.date = date
    }
}

// MARK: - Errors

/// Why a file could not be imported. Messages are user-facing.
public enum AudioImportError: Error, Equatable, LocalizedError {
    /// The file is not an audio file (wrong type, or it contains video).
    case notAudio
    /// AVFoundation could not open the file (corrupt or unsupported).
    case unreadable
    /// The file opened but has no audio track or zero duration.
    case noAudio
    /// Copying the file into Biscotti's storage failed.
    case copyFailed(String)

    public var errorDescription: String? {
        switch self {
        case .notAudio:
            "This isn't an audio file. Only sound files (mp3, m4a, wav, aac, flac, aiff) can be imported."
        case .unreadable:
            "The file couldn't be read. It may be corrupt or in an unsupported format."
        case .noAudio:
            "The file doesn't contain any audio."
        case let .copyFailed(detail):
            "Couldn't copy the file into Biscotti: \(detail)"
        }
    }
}

// MARK: - Inspecting seam

/// Seam over AVFoundation so `AppCore.importAudio` is testable without real audio.
public protocol AudioImportInspecting: Sendable {
    func inspect(url: URL) async throws -> AudioImportInfo
}

/// Production inspector: checks the file type, opens it with AVFoundation,
/// and reads the duration plus the file's date.
public struct AudioImporter: AudioImportInspecting {
    public init() {}

    /// File types the open panel and drag-and-drop accept.
    public static let allowedTypes: [UTType] = [.audio]

    public func inspect(url: URL) async throws -> AudioImportInfo {
        // 1. Cheap check by file type (extension). Video containers (mp4, mov)
        //    conform to `.movie`, not `.audio`, so they're rejected here.
        guard let type = UTType(filenameExtension: url.pathExtension),
              type.conforms(to: .audio)
        else {
            throw AudioImportError.notAudio
        }

        // 2. Confirm AVFoundation can actually decode it.
        let asset = AVURLAsset(url: url)
        let duration: TimeInterval
        let audioTracks: [AVAssetTrack]
        let videoTracks: [AVAssetTrack]
        do {
            duration = try await asset.load(.duration).seconds
            audioTracks = try await asset.loadTracks(withMediaType: .audio)
            videoTracks = try await asset.loadTracks(withMediaType: .video)
        } catch {
            throw AudioImportError.unreadable
        }
        guard videoTracks.isEmpty else { throw AudioImportError.notAudio }
        guard !audioTracks.isEmpty, duration.isFinite, duration > 0 else {
            throw AudioImportError.noAudio
        }

        // 3. The file's own date. Read from the ORIGINAL (copying resets it).
        let values = try? url.resourceValues(forKeys: [.creationDateKey, .contentModificationDateKey])
        let date = Self.effectiveDate(
            creation: values?.creationDate,
            modification: values?.contentModificationDate,
            now: Date()
        )
        return AudioImportInfo(duration: duration, date: date)
    }

    /// The meeting date for an imported file: creation date, else last-modified
    /// date, else `now` (import time) when the file has neither.
    public static func effectiveDate(creation: Date?, modification: Date?, now: Date) -> Date {
        creation ?? modification ?? now
    }
}
