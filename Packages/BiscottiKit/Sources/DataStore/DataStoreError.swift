import Foundation

/// Errors thrown by `DataStore` operations.
public enum DataStoreError: Error, Sendable, Equatable {
    case containerInitFailed(String)
    case saveFailed(String)
    case notFound(UUID)
    case associationConflict
}
