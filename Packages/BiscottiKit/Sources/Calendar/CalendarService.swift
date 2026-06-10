import DataStore
import Foundation
import MeetingCatalog
import os

/// Read-only bridge between EventKit and the rest of the app.
///
/// Owns the live event-store seam, enabled-calendar filtering, conference
/// detection (via `MeetingCatalog`), snapshot mapping, and `bestMatch` for
/// auto-association. Produces **DTOs only** -- never leaks EKEvent references.
///
/// **Error behavior:** never throws to callers. Authorization failures update
/// `auth`; fetch failures log and leave `upcoming` empty; `snapshot(forKey:)`
/// returns `nil` if the event cannot be located.
@MainActor @Observable
public final class CalendarService {
    // MARK: - Observable state

    public private(set) var auth: CalendarAuthStatus
    public private(set) var upcoming: [CalendarEvent] = []

    // MARK: - Dependencies

    private let store: DataStore
    private let catalog: any MeetingCatalog
    private let provider: any EventStoreProviding
    private let logger = Logger(
        subsystem: "net.scosman.biscotti",
        category: "Calendar"
    )

    /// Cache of enabled calendar IDs from DataStore settings.
    /// `nil` = all calendars enabled.
    private var cachedEnabledIDs: Set<String>?

    /// Cached DTOs from the last `refreshUpcoming` for snapshot lookup.
    private var cachedDTOs: [String: EKEventDTO] = [:]

    /// Observation token for `.EKEventStoreChanged`.
    /// Wrapped in a class so deinit (nonisolated in Swift 6) can clean up
    /// without accessing MainActor-isolated storage.
    private let observationBox = ObservationBox()

    // MARK: - Init

    public init(
        store: DataStore,
        catalog: any MeetingCatalog,
        provider: any EventStoreProviding = LiveEventStore()
    ) {
        self.store = store
        self.catalog = catalog
        self.provider = provider
        auth = provider.authorizationStatus()
    }

    deinit {
        observationBox.removeObserver()
    }

    // MARK: - Public API

    /// Request full calendar access. Updates `auth` with the result.
    public func requestAccess() async -> CalendarAuthStatus {
        do {
            _ = try await provider.requestAccess()
        } catch {
            logger.error("Calendar access request failed: \(error)")
        }
        let newStatus = provider.authorizationStatus()
        auth = newStatus
        return newStatus
    }

    /// All visible calendars (enabled + disabled). For settings/onboarding UI.
    public func calendars() async -> [CalendarInfo] {
        await Task.detached { [provider] in
            provider.calendars()
        }.value
    }

    /// Re-fetch meeting-like events in the given window. Updates `upcoming`.
    public func refreshUpcoming(window: DateInterval) async {
        await loadEnabledCalendarIDs()
        let calendarIDs = enabledCalendarIDsForProvider()

        let dtos = await Task.detached { [provider] in
            provider.events(in: window, calendars: calendarIDs)
        }.value

        var events: [CalendarEvent] = []
        var dtoCache: [String: EKEventDTO] = [:]

        for dto in dtos {
            // Compute conference match once; reuse for both meeting-like filter and event construction.
            let conference = conferenceResult(for: dto)
            guard isMeetingLike(dto, conference: conference) else { continue }
            let key = CompositeKey.make(
                eventIdentifier: dto.eventIdentifier,
                calendarItemIdentifier: dto.calendarItemIdentifier,
                occurrenceStartDate: dto.occurrenceDate
            )
            let event = CalendarEvent(
                id: key,
                title: dto.title ?? "(No title)",
                start: dto.startDate,
                end: dto.endDate,
                conferencePlatform: conference?.platform,
                conferenceURL: conference?.url,
                attendeeCount: dto.attendeeCount,
                calendarTitle: dto.calendarTitle,
                calendarColorHex: dto.calendarColorHex,
                isMeetingLike: true
            )
            events.append(event)
            dtoCache[key] = dto
        }

        events.sort { $0.start < $1.start }
        upcoming = events
        cachedDTOs = dtoCache
    }

    /// Look up a cached CalendarEvent by its composite key string.
    public func event(forKey key: String) -> CalendarEvent? {
        upcoming.first { $0.id == key }
    }

    /// Pick the best calendar event for auto-association at recording start.
    public func bestMatch(at date: Date) -> CalendarEvent? {
        let imminentWindow: TimeInterval = 10 * 60 // 10 minutes

        let candidates = upcoming.filter { event in
            let inProgress = event.start <= date && date <= event.end
            let imminent = event.start > date
                && event.start.timeIntervalSince(date) <= imminentWindow
            return inProgress || imminent
        }

        guard !candidates.isEmpty else { return nil }

        let scored = candidates.map { event -> (CalendarEvent, Int) in
            var score = 0
            if event.conferenceURL != nil { score += 2 }
            let inProgress = event.start <= date && date <= event.end
            if inProgress { score += 1 }
            return (event, score)
        }

        let sorted = scored.sorted { lhs, rhs in
            if lhs.1 != rhs.1 { return lhs.1 > rhs.1 }
            return abs(lhs.0.start.timeIntervalSince(date))
                < abs(rhs.0.start.timeIntervalSince(date))
        }

        return sorted.first?.0
    }

    /// Map the event identified by `key` to a CalendarSnapshotInput.
    /// Re-fetches from the provider to get the freshest fields.
    /// Returns nil if the event cannot be found (deleted since last refresh).
    public func snapshot(
        forKey key: String
    ) async -> CalendarSnapshotInput? {
        // Parse the key to get eventIdentifier and occurrenceStart
        guard let cached = cachedDTOs[key] else { return nil }

        let freshDTO = await Task.detached { [provider] in
            provider.refreshEvent(
                eventIdentifier: cached.eventIdentifier,
                occurrenceStart: cached.occurrenceDate
            )
        }.value

        guard let dto = freshDTO else { return nil }
        return mapToSnapshotInput(dto)
    }

    /// Subscribe to `.EKEventStoreChanged` and auto-refresh.
    public func startObserving() {
        let token = NotificationCenter.default.addObserver(
            forName: .EKEventStoreChanged,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                await self?.handleStoreChanged()
            }
        }
        observationBox.setToken(token)
    }

    // MARK: - Internal (exposed for testing)

    /// Computes the conference match for a DTO.
    func conferenceResult(
        for dto: EKEventDTO
    ) -> (platform: String, url: URL)? {
        catalog.conferenceMatch(
            inURL: dto.url,
            location: dto.location,
            notes: dto.notes
        )
    }

    /// Whether an event qualifies as "meeting-like."
    /// Accepts a pre-computed conference result to avoid redundant regex work.
    func isMeetingLike(
        _ dto: EKEventDTO,
        conference: (platform: String, url: URL)? = nil
    ) -> Bool {
        guard !dto.isAllDay else { return false }
        guard dto.birthdayContactIdentifier == nil else { return false }
        let conf = conference ?? conferenceResult(for: dto)
        return conf != nil || dto.attendeeCount >= 2
    }

    // MARK: - Private

    private func loadEnabledCalendarIDs() async {
        do {
            let settings = try await store.settings()
            cachedEnabledIDs = settings.enabledCalendarIDs
        } catch {
            logger.error("Failed to read settings: \(error)")
            cachedEnabledIDs = nil
        }
    }

    private func enabledCalendarIDsForProvider() -> [String]? {
        cachedEnabledIDs.map(Array.init)
    }

    private func mapToSnapshotInput(
        _ dto: EKEventDTO
    ) -> CalendarSnapshotInput {
        let key = CompositeKey.make(
            eventIdentifier: dto.eventIdentifier,
            calendarItemIdentifier: dto.calendarItemIdentifier,
            occurrenceStartDate: dto.occurrenceDate
        )

        let conference = catalog.conferenceMatch(
            inURL: dto.url,
            location: dto.location,
            notes: dto.notes
        )

        let organizerInput = dto.organizer.map { mapAttendee($0) }
        let attendeeInputs = dto.attendees.map { mapAttendee($0) }

        return CalendarSnapshotInput(
            eventIdentifier: dto.eventIdentifier,
            calendarItemIdentifier: dto.calendarItemIdentifier,
            calendarItemExternalIdentifier: dto.calendarItemExternalIdentifier,
            occurrenceStartDate: dto.occurrenceDate,
            compositeKey: key,
            title: dto.title ?? "(No title)",
            startDate: dto.startDate,
            endDate: dto.endDate,
            isAllDay: dto.isAllDay,
            location: dto.location,
            url: dto.url,
            timeZone: dto.timeZone,
            eventNotes: dto.notes ?? "",
            status: dto.status,
            availability: dto.availability,
            calendarTitle: dto.calendarTitle,
            calendarColorHex: dto.calendarColorHex,
            conferenceURL: conference?.url,
            conferencePlatform: conference?.platform,
            organizer: organizerInput,
            attendees: attendeeInputs
        )
    }

    private func mapAttendee(_ dto: AttendeeDTO) -> AttendeeInput {
        AttendeeInput(
            name: dto.name,
            email: EmailParser.email(from: dto.participantURL),
            isCurrentUser: dto.isCurrentUser,
            role: dto.role,
            status: dto.status,
            type: dto.type
        )
    }

    private func handleStoreChanged() async {
        // Re-fetch upcoming events with a 24h window
        let now = Date()
        let window = DateInterval(
            start: now,
            end: now.addingTimeInterval(24 * 60 * 60)
        )
        await refreshUpcoming(window: window)

        // Check staleness for recent meetings with snapshots
        await checkStaleness()
    }

    private func checkStaleness() async {
        do {
            let recentWithSnapshots = try await store
                .recentMeetingsWithSnapshots(
                    since: Date().addingTimeInterval(-7 * 24 * 60 * 60)
                )

            for entry in recentWithSnapshots {
                let refreshed = await Task.detached { [provider] in
                    provider.refreshEvent(
                        eventIdentifier: entry.eventIdentifier,
                        occurrenceStart: entry.occurrenceStart
                    )
                }.value

                if refreshed == nil {
                    try await store.markSnapshotStale(
                        meetingID: entry.meetingID
                    )
                }
            }
        } catch {
            logger.error("Staleness check failed: \(error)")
        }
    }
}

// MARK: - Observation cleanup helper

/// Thread-safe wrapper so `CalendarService.deinit` (nonisolated in Swift 6)
/// can remove the NotificationCenter observer without accessing
/// MainActor-isolated storage. Uses `NSLock` for synchronization;
/// `@unchecked Sendable` is needed because `NSObjectProtocol` is not
/// `Sendable`, but access is guarded by the lock.
final class ObservationBox: @unchecked Sendable {
    private let lock = NSLock()
    private var token: (any NSObjectProtocol)?

    func setToken(_ newToken: any NSObjectProtocol) {
        lock.lock()
        token = newToken
        lock.unlock()
    }

    func removeObserver() {
        lock.lock()
        let captured = token
        token = nil
        lock.unlock()
        if let captured {
            NotificationCenter.default.removeObserver(captured)
        }
    }
}
