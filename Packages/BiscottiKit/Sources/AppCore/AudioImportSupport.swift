import AppKit
import Foundation
import UniformTypeIdentifiers

// MARK: - Supported types

/// What the "Import Audio File..." entry points (File menu, toolbar,
/// menu-bar popover, drag-and-drop) accept, plus the live open panel.
///
/// The type filter is only a first gate for friendly UX; the real check is
/// `AudioFileImporter.validate`, which opens the file with AVFoundation.
public enum AudioImportSupport {
    /// Open-panel filter: any audio, any movie (video files with an audio
    /// track), and the common formats spelled out so extension-only files
    /// (flac, aac) are selectable on every macOS version.
    public static var allowedContentTypes: [UTType] {
        let named: [UTType?] = [
            .audio, .movie, .mpeg4Movie, .mpeg4Audio, .mp3, .wav, .aiff,
            UTType(filenameExtension: "m4a"),
            UTType(filenameExtension: "aac"),
            UTType(filenameExtension: "flac")
        ]
        return named.compactMap(\.self)
    }

    /// Whether `url` looks like an audio or video file. Directories and
    /// non-file URLs are rejected; a file whose content type cannot be read
    /// (missing, no metadata) falls back to its extension.
    public static func isSupported(_ url: URL) -> Bool {
        guard url.isFileURL else { return false }
        let values = try? url.resourceValues(forKeys: [.contentTypeKey, .isDirectoryKey])
        if values?.isDirectory == true { return false }
        guard let type = values?.contentType
            ?? UTType(filenameExtension: url.pathExtension)
        else { return false }
        return type.conforms(to: .audio) || type.conforms(to: .movie)
    }

    /// The user-facing reason an unsupported file is skipped.
    public static let unsupportedMessage =
        "Only audio and video files can be imported."

    /// Live open panel: multiple audio/video files. Returns `[]` on cancel.
    @MainActor
    public static func presentOpenPanel() -> [URL] {
        let panel = NSOpenPanel()
        panel.title = "Import Audio File"
        panel.prompt = "Import"
        panel.allowedContentTypes = allowedContentTypes
        panel.allowsMultipleSelection = true
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        guard panel.runModal() == .OK else { return [] }
        return panel.urls
    }
}

// MARK: - Failure reporting

/// One file that could not be imported.
public struct AudioImportFailure: Sendable, Equatable {
    public let fileName: String
    public let message: String

    public init(fileName: String, message: String) {
        self.fileName = fileName
        self.message = message
    }
}

/// The alert copy for a batch of import failures: "Couldn't import <name>"
/// plus the error's description, or a per-file list when several failed.
public struct AudioImportAlert: Sendable, Equatable {
    public let title: String
    public let message: String

    /// - Returns: nil when `failures` is empty.
    public init?(failures: [AudioImportFailure]) {
        guard let first = failures.first else { return nil }
        if failures.count == 1 {
            title = "Couldn\u{2019}t import \(first.fileName)"
            message = first.message
        } else {
            title = "Couldn\u{2019}t import \(failures.count) files"
            message = failures
                .map { "\($0.fileName): \($0.message)" }
                .joined(separator: "\n")
        }
    }
}
