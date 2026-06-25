import SwiftData

/// V1 schema declaration. All `@Model` types that make up the first version
/// of the persistent store are listed here.
public enum DataStoreSchemaV1: VersionedSchema {
    public static let versionIdentifier = Schema.Version(1, 0, 0)

    public static var models: [any PersistentModel.Type] {
        [
            Meeting.self,
            Tag.self,
            Person.self,
            TranscriptRecord.self,
            TranscriptSegmentRecord.self,
            TranscriptWordRecord.self,
            AudioFileRef.self,
            CalendarSnapshot.self,
            AppSettings.self
        ]
    }
}
