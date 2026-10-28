import Foundation
import SwiftData

public extension DataStore {
    /// Every person that some meeting's calendar snapshot marks as the
    /// current user. A saved transcript places a speaker assigned to one of
    /// them on the "You" side.
    func currentUserPersonIDs() throws -> Set<UUID> {
        var descriptor = FetchDescriptor<CalendarSnapshot>(
            predicate: #Predicate { $0.currentUserPersonID != nil }
        )
        descriptor.propertiesToFetch = [\.currentUserPersonID]
        return try Set(context.fetch(descriptor).compactMap(\.currentUserPersonID))
    }
}
