import Foundation

/// The top-level manifest of a bundle folder sent to the runner Mac.
public struct BundleManifest: Codable, Sendable, Equatable {
    public var schemaVersion: Int
    public var bundleID: UUID
    public var createdAt: Date
    public var toolVersion: String
    public var meetings: [String]

    public init(
        schemaVersion: Int = SchemaVersions.bundle,
        bundleID: UUID = UUID(),
        createdAt: Date = Date(),
        toolVersion: String = STTLabCore.toolVersion,
        meetings: [String]
    ) {
        self.schemaVersion = schemaVersion
        self.bundleID = bundleID
        self.createdAt = createdAt
        self.toolVersion = toolVersion
        self.meetings = meetings
    }
}
