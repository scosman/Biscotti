import SwiftData

/// Migration plan for the DataStore schema. Currently contains only V1;
/// future schema versions add stages here for lossless migration.
public enum DataStoreMigrationPlan: SchemaMigrationPlan {
    public static var schemas: [any VersionedSchema.Type] {
        [DataStoreSchemaV1.self]
    }

    public static var stages: [MigrationStage] {
        []
    }
}
