import XCTest

@testable import EventKitLab

final class SnapshotModelTests: XCTestCase {
    // MARK: - EventLinkKey

    func testCompositeKeyEquality() {
        let date = Date(timeIntervalSince1970: 1_000_000)
        let key1 = EventLinkKey(
            eventIdentifier: "evt-1",
            calendarItemIdentifier: "cal-1",
            occurrenceStartDate: date
        )
        let key2 = EventLinkKey(
            eventIdentifier: "evt-1",
            calendarItemIdentifier: "cal-1",
            occurrenceStartDate: date
        )
        XCTAssertEqual(key1, key2)
    }

    func testCompositeKeyInequalityDifferentDate() {
        let key1 = EventLinkKey(
            eventIdentifier: "evt-1",
            calendarItemIdentifier: "cal-1",
            occurrenceStartDate: Date(timeIntervalSince1970: 1_000_000)
        )
        let key2 = EventLinkKey(
            eventIdentifier: "evt-1",
            calendarItemIdentifier: "cal-1",
            occurrenceStartDate: Date(timeIntervalSince1970: 2_000_000)
        )
        XCTAssertNotEqual(key1, key2)
    }

    func testCompositeKeyInequalityDifferentEventID() {
        let date = Date(timeIntervalSince1970: 1_000_000)
        let key1 = EventLinkKey(
            eventIdentifier: "evt-1",
            calendarItemIdentifier: "cal-1",
            occurrenceStartDate: date
        )
        let key2 = EventLinkKey(
            eventIdentifier: "evt-2",
            calendarItemIdentifier: "cal-1",
            occurrenceStartDate: date
        )
        XCTAssertNotEqual(key1, key2)
    }

    func testCompositeKeyHashingInSet() {
        let date = Date(timeIntervalSince1970: 1_000_000)
        let key1 = EventLinkKey(
            eventIdentifier: "evt-1",
            calendarItemIdentifier: "cal-1",
            occurrenceStartDate: date
        )
        let key2 = EventLinkKey(
            eventIdentifier: "evt-1",
            calendarItemIdentifier: "cal-1",
            occurrenceStartDate: date
        )
        let key3 = EventLinkKey(
            eventIdentifier: "evt-2",
            calendarItemIdentifier: "cal-2",
            occurrenceStartDate: date
        )
        var set = Set<EventLinkKey>()
        set.insert(key1)
        set.insert(key2)
        set.insert(key3)
        XCTAssertEqual(set.count, 2)
    }

    func testCompositeKeyCodable() throws {
        let key = EventLinkKey(
            eventIdentifier: "evt-1",
            calendarItemIdentifier: "cal-1",
            occurrenceStartDate: Date(timeIntervalSince1970: 1_000_000)
        )
        let data = try JSONEncoder().encode(key)
        let decoded = try JSONDecoder().decode(EventLinkKey.self, from: data)
        XCTAssertEqual(key, decoded)
    }

    // MARK: - Email parsing

    func testEmailFromMailtoURL() {
        let url = URL(string: "mailto:john@example.com")!
        XCTAssertEqual(emailFromParticipantURL(url), "john@example.com")
    }

    func testEmailFromNonMailtoURLReturnsNil() {
        let url = URL(string: "https://example.com/profile")!
        XCTAssertNil(emailFromParticipantURL(url))
    }

    func testEmailFromMailtoURLWithEmptySpecifier() {
        let url = URL(string: "mailto:")!
        XCTAssertNil(emailFromParticipantURL(url))
    }

    // MARK: - AttendeeSnapshot

    func testAttendeeSnapshotCodable() throws {
        let attendee = AttendeeSnapshot(
            name: "Jane Doe",
            email: "jane@example.com",
            participantURLString: "mailto:jane@example.com",
            isCurrentUser: false,
            role: "required",
            status: "accepted",
            type: "person"
        )
        let data = try JSONEncoder().encode(attendee)
        let decoded = try JSONDecoder().decode(AttendeeSnapshot.self, from: data)
        XCTAssertEqual(decoded.name, "Jane Doe")
        XCTAssertEqual(decoded.email, "jane@example.com")
        XCTAssertEqual(decoded.participantURLString, "mailto:jane@example.com")
        XCTAssertEqual(decoded.isCurrentUser, false)
        XCTAssertEqual(decoded.role, "required")
        XCTAssertEqual(decoded.status, "accepted")
        XCTAssertEqual(decoded.type, "person")
    }

    func testAttendeeSnapshotWithNilFields() throws {
        let attendee = AttendeeSnapshot(
            name: nil,
            email: nil,
            participantURLString: nil,
            isCurrentUser: true,
            role: "chair",
            status: "pending",
            type: "unknown"
        )
        let data = try JSONEncoder().encode(attendee)
        let decoded = try JSONDecoder().decode(AttendeeSnapshot.self, from: data)
        XCTAssertNil(decoded.name)
        XCTAssertNil(decoded.email)
        XCTAssertTrue(decoded.isCurrentUser)
    }

    // MARK: - AttendeeSnapshot enrichmentKey

    func testEnrichmentKeyWithEmail() {
        let attendee = AttendeeSnapshot(
            name: "Jane Doe",
            email: "jane@example.com",
            participantURLString: "mailto:jane@example.com",
            isCurrentUser: false,
            role: "required",
            status: "accepted",
            type: "person"
        )
        XCTAssertEqual(attendee.enrichmentKey, "Jane Doe|jane@example.com")
    }

    func testEnrichmentKeyWithNonMailtoURL() {
        // Exchange/X500 attendees have no email but do have a participant URL
        let attendee = AttendeeSnapshot(
            name: "jsmith",
            email: nil,
            participantURLString: "/o=ExchangeLabs/ou=Exchange/cn=Recipients/cn=jsmith",
            isCurrentUser: false,
            role: "required",
            status: "accepted",
            type: "person"
        )
        XCTAssertEqual(
            attendee.enrichmentKey,
            "jsmith|/o=ExchangeLabs/ou=Exchange/cn=Recipients/cn=jsmith"
        )
    }

    func testEnrichmentKeyWithNilEmailAndNilURL() {
        let attendee = AttendeeSnapshot(
            name: "Mystery Person",
            email: nil,
            participantURLString: nil,
            isCurrentUser: false,
            role: "optional",
            status: "pending",
            type: "person"
        )
        XCTAssertEqual(attendee.enrichmentKey, "Mystery Person|unknown")
    }

    // MARK: - CalendarEventSnapshot

    func testCalendarEventSnapshotCodable() throws {
        let snapshot = makeFullSnapshot()

        let data = try JSONEncoder().encode(snapshot)
        let decoded = try JSONDecoder().decode(CalendarEventSnapshot.self, from: data)
        XCTAssertEqual(decoded.title, "Team Standup")
        XCTAssertEqual(decoded.attendees.count, 1)
        XCTAssertEqual(decoded.conferencePlatform, "meet")
        XCTAssertEqual(decoded.linkKey.eventIdentifier, "evt-1")
        XCTAssertEqual(decoded.calendarIdentifier, "cal-uuid-work")
        XCTAssertNil(decoded.lastSyncDate)
        XCTAssertFalse(decoded.isStale)
    }

    func testCalendarEventSnapshotIdIsStable() {
        let snapshot = makeFullSnapshot()
        // id uses Int64 truncation of timeInterval, not Double.description
        let expected = "evt-1-\(Int64(Date(timeIntervalSince1970: 1_000_000).timeIntervalSince1970))"
        XCTAssertEqual(snapshot.id, expected)
    }

    // MARK: - Participant description helpers

    func testParticipantRoleDescriptions() {
        XCTAssertEqual(participantRoleDescription(.unknown), "unknown")
        XCTAssertEqual(participantRoleDescription(.required), "required")
        XCTAssertEqual(participantRoleDescription(.optional), "optional")
        XCTAssertEqual(participantRoleDescription(.chair), "chair")
        XCTAssertEqual(participantRoleDescription(.nonParticipant), "nonParticipant")
    }

    func testParticipantStatusDescriptions() {
        XCTAssertEqual(participantStatusDescription(.accepted), "accepted")
        XCTAssertEqual(participantStatusDescription(.declined), "declined")
        XCTAssertEqual(participantStatusDescription(.tentative), "tentative")
        XCTAssertEqual(participantStatusDescription(.pending), "pending")
    }

    func testEventAvailabilityDescriptions() {
        XCTAssertEqual(eventAvailabilityDescription(.busy), "busy")
        XCTAssertEqual(eventAvailabilityDescription(.free), "free")
        XCTAssertEqual(eventAvailabilityDescription(.tentative), "tentative")
    }

    func testEventStatusDescriptions() {
        XCTAssertEqual(eventStatusDescription(.confirmed), "confirmed")
        XCTAssertEqual(eventStatusDescription(.tentative), "tentative")
        XCTAssertEqual(eventStatusDescription(.canceled), "canceled")
    }

    // MARK: - EnrichedAttendee

    func testEnrichedAttendeeComparison() {
        let ekOnly = AttendeeSnapshot(
            name: "jsmith",
            email: nil,
            participantURLString: "mailto:jsmith@company.com",
            isCurrentUser: false,
            role: "required",
            status: "accepted",
            type: "person"
        )

        let enriched = EnrichedAttendee(
            ekParticipantData: ekOnly,
            contactName: "John Smith",
            contactEmail: "john.smith@company.com",
            contactOrganization: "Acme Corp",
            contactImageAvailable: true,
            contactFound: true
        )

        XCTAssertEqual(enriched.ekParticipantData.name, "jsmith")
        XCTAssertNil(enriched.ekParticipantData.email)
        XCTAssertEqual(enriched.contactName, "John Smith")
        XCTAssertEqual(enriched.contactEmail, "john.smith@company.com")
        XCTAssertEqual(enriched.contactOrganization, "Acme Corp")
        XCTAssertTrue(enriched.contactImageAvailable)
        XCTAssertTrue(enriched.contactFound)
    }

    func testEnrichedAttendeeNoContactMatch() {
        let ekOnly = AttendeeSnapshot(
            name: "Unknown Person",
            email: "unknown@external.com",
            participantURLString: "mailto:unknown@external.com",
            isCurrentUser: false,
            role: "optional",
            status: "pending",
            type: "person"
        )

        let enriched = EnrichedAttendee(
            ekParticipantData: ekOnly,
            contactName: nil,
            contactEmail: nil,
            contactOrganization: nil,
            contactImageAvailable: false,
            contactFound: false
        )

        XCTAssertFalse(enriched.contactFound)
        XCTAssertNil(enriched.contactName)
    }

    func testEnrichedAttendeeKeyConsistencyForNonMailtoURL() {
        // Simulates an Exchange attendee with an X500 URL (no mailto:, so email is nil).
        // Verifies that the enrichmentKey used for storage matches the key used for lookup.
        let x500URL = "/o=ExchangeLabs/ou=Exchange/cn=Recipients/cn=jsmith"
        let attendee = AttendeeSnapshot(
            name: "jsmith",
            email: nil,
            participantURLString: x500URL,
            isCurrentUser: false,
            role: "required",
            status: "accepted",
            type: "person"
        )

        // Simulate storage: manager builds enrichedAttendees dict using enrichmentKey
        var enrichedDict: [String: EnrichedAttendee] = [:]
        let enriched = EnrichedAttendee(
            ekParticipantData: attendee,
            contactName: "John Smith",
            contactEmail: "john@company.com",
            contactOrganization: nil,
            contactImageAvailable: false,
            contactFound: true
        )
        enrichedDict[attendee.enrichmentKey] = enriched

        // Simulate lookup: view looks up using the same attendee's enrichmentKey
        let lookedUp = enrichedDict[attendee.enrichmentKey]
        XCTAssertNotNil(lookedUp, "Enrichment lookup should find the stored entry using the same key")
        XCTAssertEqual(lookedUp?.contactName, "John Smith")
    }

    // MARK: - Helpers

    private func makeFullSnapshot() -> CalendarEventSnapshot {
        CalendarEventSnapshot(
            linkKey: EventLinkKey(
                eventIdentifier: "evt-1",
                calendarItemIdentifier: "cal-1",
                occurrenceStartDate: Date(timeIntervalSince1970: 1_000_000)
            ),
            calendarItemExternalIdentifier: "ext-1",
            title: "Team Standup",
            notes: "Daily sync meeting",
            startDate: Date(timeIntervalSince1970: 1_000_000),
            endDate: Date(timeIntervalSince1970: 1_001_800),
            isAllDay: false,
            location: "Conference Room A",
            url: URL(string: "https://meet.google.com/abc-def-ghi"),
            timeZoneIdentifier: "America/New_York",
            availability: "busy",
            status: "confirmed",
            organizerName: "John Smith",
            organizerEmail: "john@example.com",
            organizerIsCurrentUser: false,
            calendarIdentifier: "cal-uuid-work",
            calendarTitle: "Work",
            calendarColorHex: "#0000FF",
            attendees: [
                AttendeeSnapshot(
                    name: "Jane",
                    email: "jane@example.com",
                    participantURLString: "mailto:jane@example.com",
                    isCurrentUser: true,
                    role: "required",
                    status: "accepted",
                    type: "person"
                ),
            ],
            conferenceURL: URL(string: "https://meet.google.com/abc-def-ghi"),
            conferencePlatform: "meet",
            snapshotDate: Date(),
            lastSyncDate: nil,
            isStale: false
        )
    }
}
