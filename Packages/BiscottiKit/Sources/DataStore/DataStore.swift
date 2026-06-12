import Foundation
import SwiftData

/// The single owner of all persistent data. All mutations go through this actor;
/// queries use `FetchDescriptor` + `#Predicate`.
///
/// **Thread-safety contract:** SwiftData `@Model` objects are **not** `Sendable`
/// (the macro marks the conformance unavailable on purpose), so they must never
/// cross the actor boundary. Off-actor callers get data through the `Sendable`
/// read-model projections in `DataStore+ReadModels`, through identifiers/`Bool`
/// helpers (e.g. ``meetingExists(id:)``), or — for tests and internal verification
/// — by running a closure on the actor via ``read(_:)`` and returning only a
/// `Sendable` result. Methods such as ``meeting(id:)`` that return raw models are
/// for on-actor use only.
public actor DataStore {
    /// Storage configuration for the model container.
    public enum Storage: Sendable {
        /// Persists to disk at the given directory URL.
        case onDisk(URL)
        /// In-memory only (for tests).
        case inMemory
    }

    private let container: ModelContainer
    let context: ModelContext

    /// Creates a DataStore with the given storage configuration.
    /// - Parameters:
    ///   - storage: Where to persist data.
    ///   - cloudKit: Whether to enable CloudKit mirroring (wired but off by default).
    public init(storage: Storage, cloudKit: Bool = false) throws {
        let schema = Schema(DataStoreSchemaV1.models)

        let config = switch storage {
        case let .onDisk(url):
            ModelConfiguration(
                "Biscotti",
                schema: schema,
                url: url.appending(path: "Biscotti.store"),
                cloudKitDatabase: cloudKit ? .automatic : .none
            )
        case .inMemory:
            ModelConfiguration(
                "Biscotti",
                schema: schema,
                isStoredInMemoryOnly: true,
                cloudKitDatabase: cloudKit ? .automatic : .none
            )
        }

        do {
            // TODO: re-wire `migrationPlan: DataStoreMigrationPlan.self` once a
            // breaking schema change requires V2. Currently V1-only; additive
            // defaulted properties are handled automatically by SwiftData.
            container = try ModelContainer(
                for: schema,
                configurations: [config]
            )
        } catch {
            throw DataStoreError.containerInitFailed(error.localizedDescription)
        }

        context = ModelContext(container)
        context.autosaveEnabled = true
    }

    // MARK: - Meeting CRUD

    /// Creates a new meeting and returns its ID.
    @discardableResult
    public func createMeeting(title: String, start: Date? = nil, end: Date? = nil) throws -> UUID {
        let meeting = Meeting(title: title, startDate: start, endDate: end)
        context.insert(meeting)
        try save()
        return meeting.id
    }

    /// Fetches a meeting by ID, or nil if not found.
    ///
    /// The returned `Meeting` is **not** `Sendable` and must only be read on this
    /// actor. Off-actor callers that just need existence should use
    /// ``meetingExists(id:)``; callers that need data should use the read-model
    /// projections in `DataStore+ReadModels`.
    public func meeting(id: UUID) throws -> Meeting? {
        let descriptor = FetchDescriptor<Meeting>(
            predicate: #Predicate { $0.id == id }
        )
        return try context.fetch(descriptor).first
    }

    /// Returns whether a meeting with the given ID exists. Returns a `Sendable`
    /// `Bool`, so it is safe to call across the actor boundary (unlike
    /// ``meeting(id:)``, which returns a non-`Sendable` model).
    public func meetingExists(id: UUID) throws -> Bool {
        var descriptor = FetchDescriptor<Meeting>(
            predicate: #Predicate { $0.id == id }
        )
        descriptor.fetchLimit = 1
        return try context.fetchCount(descriptor) > 0
    }

    /// Returns the most recently created meetings, ordered by `createdAt` descending.
    public func recentMeetings(limit: Int) throws -> [Meeting] {
        var descriptor = FetchDescriptor<Meeting>(
            sortBy: [SortDescriptor(\.createdAt, order: .reverse)]
        )
        descriptor.fetchLimit = limit
        return try context.fetch(descriptor)
    }

    /// Returns upcoming meetings (startDate >= now), ordered by `startDate` ascending.
    public func upcomingMeetings(now: Date, limit: Int) throws -> [Meeting] {
        // Fetch all, filter in-memory -- SwiftData predicates don't support
        // force-unwrap or optional comparisons on Date?.
        let descriptor = FetchDescriptor<Meeting>(
            sortBy: [SortDescriptor(\.startDate, order: .forward)]
        )
        let all = try context.fetch(descriptor)
        let filtered = all.filter { meeting in
            guard let start = meeting.startDate else { return false }
            return start >= now
        }
        return Array(filtered.prefix(limit))
    }

    /// Sets the recording duration for a meeting.
    public func setRecordingDuration(
        _ duration: TimeInterval, for meetingID: UUID
    ) throws {
        guard let meeting = try meeting(id: meetingID) else {
            throw DataStoreError.notFound(meetingID)
        }
        meeting.recordingDuration = duration
        try save()
    }

    /// Deletes a meeting by ID. Throws `notFound` if the meeting does not exist.
    public func delete(meetingID: UUID) throws {
        guard let meeting = try meeting(id: meetingID) else {
            throw DataStoreError.notFound(meetingID)
        }
        context.delete(meeting)
        try save()
    }

    // MARK: - People

    /// Finds an existing person (by email case-insensitive, then by exact name)
    /// or creates a new one. Returns the person's ID.
    @discardableResult
    public func findOrCreatePerson(name: String, email: String?) throws -> UUID {
        // First try to match by email (case-insensitive) if provided
        if let email, !email.isEmpty {
            let lowered = email.lowercased()
            // Full-table scan + in-memory filter: case-insensitive email comparison
            // isn't expressible in SwiftData #Predicate. Acceptable at V1 scale.
            let descriptor = FetchDescriptor<Person>()
            let all = try context.fetch(descriptor)
            if let match = all.first(where: { $0.email?.lowercased() == lowered }) {
                // Return the existing person as-is. We deliberately do NOT update its
                // name — silently overwriting could clobber a user-corrected name.
                // Name reconciliation is out of scope for 3.1.
                return match.id
            }
        }

        // Then try to match by exact name (only if no email provided)
        if email == nil || email?.isEmpty == true {
            let descriptor = FetchDescriptor<Person>(
                predicate: #Predicate { $0.name == name }
            )
            if let match = try context.fetch(descriptor).first {
                return match.id
            }
        }

        // Create new person
        let person = Person(name: name, email: email)
        context.insert(person)
        try save()
        return person.id
    }

    /// Sets the participants (many-to-many) and organizer (to-one) for a meeting.
    /// Replaces any existing participants/organizer.
    public func setParticipants(
        _ personIDs: [UUID],
        organizer organizerID: UUID?,
        for meetingID: UUID
    ) throws {
        guard let meeting = try meeting(id: meetingID) else {
            throw DataStoreError.notFound(meetingID)
        }

        // Resolve participants
        var people: [Person] = []
        for personID in personIDs {
            let descriptor = FetchDescriptor<Person>(
                predicate: #Predicate { $0.id == personID }
            )
            guard let person = try context.fetch(descriptor).first else {
                throw DataStoreError.notFound(personID)
            }
            people.append(person)
        }

        // Resolve organizer
        var organizerPerson: Person?
        if let organizerID {
            let descriptor = FetchDescriptor<Person>(
                predicate: #Predicate { $0.id == organizerID }
            )
            guard let person = try context.fetch(descriptor).first else {
                throw DataStoreError.notFound(organizerID)
            }
            organizerPerson = person
        }

        meeting.participants = people
        meeting.organizer = organizerPerson
        try save()
    }

    // MARK: - Private

    func save() throws {
        do {
            try context.save()
        } catch {
            throw DataStoreError.saveFailed(error.localizedDescription)
        }
    }
}
