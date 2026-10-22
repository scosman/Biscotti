import Foundation

/// Schema version constants for all persisted JSON files.
/// Bump a version when the schema changes in a way that older readers cannot handle.
public enum SchemaVersions {
    public static let bundle = 1
    public static let appleResult = 1
    public static let whisper = 1
    public static let diarization = 1
    public static let reference = 1
    public static let selection = 1
    public static let runFile = 1
}

/// Tool version string embedded in manifests and outputs.
public let toolVersion = "1.0"
