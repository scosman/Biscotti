import Foundation
import SwiftData

// MARK: - AudioRole

/// The role an audio file plays in a recording session.
public enum AudioRole: String, Codable, Sendable {
    case mic
    case system
}

// MARK: - AudioFileRef

/// A reference to a recorded audio file on disk. Two per meeting (mic + system).
@Model public final class AudioFileRef: @unchecked Sendable {
    #Unique<AudioFileRef>([\.id])

    public var id: UUID
    public var role: AudioRole
    /// Security-scoped bookmark for sandbox-safe access.
    public var bookmark: Data?
    public var path: String
    public var byteSize: Int64
    /// False when the file is missing on disk (detected by `markAudioPresence`).
    public var isPresent: Bool

    public init(
        id: UUID = UUID(),
        role: AudioRole,
        bookmark: Data? = nil,
        path: String,
        byteSize: Int64,
        isPresent: Bool = true
    ) {
        self.id = id
        self.role = role
        self.bookmark = bookmark
        self.path = path
        self.byteSize = byteSize
        self.isPresent = isPresent
    }
}
