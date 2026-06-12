import SwiftData

/// Migration plan for the DataStore schema.
///
/// Currently single-version (V1). New properties added to V1 models with
/// defaults are handled automatically by SwiftData without explicit migration
/// stages. When a breaking schema change is needed (e.g. removing a property
/// or changing a type), add a V2 VersionedSchema with its own model snapshots
/// and a lightweight or custom migration stage here.
public enum DataStoreMigrationPlan: SchemaMigrationPlan {
    public static var schemas: [any VersionedSchema.Type] {
        [DataStoreSchemaV1.self]
    }

    public static var stages: [MigrationStage] {
        []
    }
}
