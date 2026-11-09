import Foundation

/// One thing to import, as handed over by the UI.
public enum ImportEntry: Sendable {
    /// A local file (Finder drag, open panel).
    case file(URL)
    /// A file promise (Voice Memos, Photos). `displayName` is the promised
    /// name if the source app supplied one. `deliver` resolves to the
    /// received file's URL (in a temp dir owned by the UI layer) or throws.
    case promised(
        displayName: String?,
        deliver: @Sendable () async throws -> URL
    )
}

public enum ImportItemStatus: Sendable, Equatable {
    case receiving
    case waiting
    case converting
    case done(meetingID: UUID)
    case failed(ImportFailure)
}

public enum ImportFailure: Error, Sendable, Equatable {
    case noAudio
    case sourceMissing
    case saveFailed
    case unreadable

    /// User-facing copy (functional spec section 5.4).
    public var message: String {
        switch self {
        case .noAudio: "This file has no audio."
        case .sourceMissing: "This file was moved or deleted."
        case .saveFailed: "Couldn't save the converted audio."
        case .unreadable: "Couldn't convert this file. It may be damaged."
        }
    }
}

public struct ImportItem: Identifiable, Sendable, Equatable {
    public let id: UUID
    public let batchID: UUID
    public internal(set) var displayName: String
    public internal(set) var sourceURL: URL?
    public internal(set) var meetingDate: Date?
    public internal(set) var status: ImportItemStatus
    public let addedAt: Date
    public let isPromised: Bool

    public init(
        id: UUID = UUID(),
        batchID: UUID,
        displayName: String,
        sourceURL: URL? = nil,
        meetingDate: Date? = nil,
        status: ImportItemStatus,
        addedAt: Date,
        isPromised: Bool
    ) {
        self.id = id
        self.batchID = batchID
        self.displayName = displayName
        self.sourceURL = sourceURL
        self.meetingDate = meetingDate
        self.status = status
        self.addedAt = addedAt
        self.isPromised = isPromised
    }
}

/// A stretch of continuous conversion work (functional spec section 4.1).
public struct ImportRun: Sendable, Equatable {
    public let startIndex: Int
    public internal(set) var count: Int

    public init(startIndex: Int, count: Int) {
        self.startIndex = startIndex
        self.count = count
    }
}

/// Passed to `onItemFinished` after an item reaches `.done` or `.failed`.
public struct ImportFinished: Sendable {
    public let item: ImportItem
    public let batchSize: Int

    public init(item: ImportItem, batchSize: Int) {
        self.item = item
        self.batchSize = batchSize
    }
}

/// Result of a successful file conversion.
public struct ConversionResult: Sendable, Equatable {
    /// Audio duration: frames written / 24_000.
    public let duration: TimeInterval
    /// Output file size on disk.
    public let byteSize: Int64

    public init(duration: TimeInterval, byteSize: Int64) {
        self.duration = duration
        self.byteSize = byteSize
    }
}
