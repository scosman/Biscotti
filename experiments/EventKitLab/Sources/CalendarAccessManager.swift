import Contacts
import EventKit
import SwiftUI

@MainActor
@Observable
final class CalendarAccessManager {
    let eventStore = EKEventStore()
    let contactStore = CNContactStore()

    private(set) var calendarAuthStatus: EKAuthorizationStatus = EKEventStore.authorizationStatus(for: .event)
    private(set) var contactsAuthStatus: CNAuthorizationStatus = CNContactStore.authorizationStatus(for: .contacts)

    private(set) var calendars: [EKCalendar] = []
    private(set) var events: [EKEvent] = []
    private(set) var snapshots: [CalendarEventSnapshot] = []
    private(set) var enrichedAttendees: [String: EnrichedAttendee] = [:]

    var enabledCalendarIDs: Set<String> {
        get {
            let saved = UserDefaults.standard.stringArray(forKey: "enabledCalendarIDs")
            if let saved {
                return Set(saved)
            }
            return Set(calendars.map(\.calendarIdentifier))
        }
        set {
            UserDefaults.standard.set(Array(newValue), forKey: "enabledCalendarIDs")
        }
    }

    private(set) var errorMessage: String?

    var hasCalendarAccess: Bool {
        calendarAuthStatus == .fullAccess || calendarAuthStatus == .authorized
    }

    var hasContactsAccess: Bool {
        contactsAuthStatus == .authorized
    }

    // MARK: - Calendar Authorization

    func requestCalendarAccess() async {
        calendarAuthStatus = EKEventStore.authorizationStatus(for: .event)

        switch calendarAuthStatus {
        case .notDetermined:
            do {
                let granted = try await eventStore.requestFullAccessToEvents()
                calendarAuthStatus = EKEventStore.authorizationStatus(for: .event)
                if granted {
                    loadCalendars()
                }
            } catch {
                errorMessage = "Failed to request calendar access: \(error.localizedDescription)"
            }
        case .fullAccess, .authorized:
            loadCalendars()
        case .denied, .restricted, .writeOnly:
            break
        @unknown default:
            break
        }
    }

    // MARK: - Contacts Authorization

    func requestContactsAccess() async {
        contactsAuthStatus = CNContactStore.authorizationStatus(for: .contacts)

        switch contactsAuthStatus {
        case .notDetermined:
            do {
                let granted = try await contactStore.requestAccess(for: .contacts)
                contactsAuthStatus = CNContactStore.authorizationStatus(for: .contacts)
                if !granted {
                    errorMessage = "Contacts access was denied."
                }
            } catch {
                errorMessage = "Failed to request contacts access: \(error.localizedDescription)"
            }
        case .authorized:
            break
        case .denied, .restricted:
            break
        @unknown default:
            break
        }
    }

    // MARK: - Calendars

    func loadCalendars() {
        guard hasCalendarAccess else { return }
        calendars = eventStore.calendars(for: .event).sorted { $0.title < $1.title }
    }

    func toggleCalendar(_ calendar: EKCalendar) {
        var ids = enabledCalendarIDs
        if ids.contains(calendar.calendarIdentifier) {
            ids.remove(calendar.calendarIdentifier)
        } else {
            ids.insert(calendar.calendarIdentifier)
        }
        enabledCalendarIDs = ids
    }

    func isCalendarEnabled(_ calendar: EKCalendar) -> Bool {
        enabledCalendarIDs.contains(calendar.calendarIdentifier)
    }

    // MARK: - Events

    func fetchEvents(from startDate: Date, to endDate: Date) {
        guard hasCalendarAccess else { return }

        let enabledIDs = enabledCalendarIDs
        let selectedCalendars = calendars.filter { enabledIDs.contains($0.calendarIdentifier) }

        guard !selectedCalendars.isEmpty else {
            events = []
            snapshots = []
            return
        }

        let predicate = eventStore.predicateForEvents(
            withStart: startDate,
            end: endDate,
            calendars: selectedCalendars
        )
        // NOTE: events(matching:) is synchronous and runs on @MainActor here.
        // Production code should move this off the main thread to avoid blocking the UI.
        events = eventStore.events(matching: predicate).sorted { $0.startDate < $1.startDate }
        snapshots = events.map { snapshotFromEvent($0) }
    }

    // MARK: - Contacts Enrichment

    func enrichAttendeesWithContacts() {
        guard hasContactsAccess else { return }

        enrichedAttendees = [:]

        for event in events {
            guard let attendees = event.attendees else { continue }
            for participant in attendees {
                let ekOnly = snapshotFromParticipant(participant)
                let key = ekOnly.enrichmentKey
                if enrichedAttendees[key] != nil { continue }

                let contactInfo = lookupContact(for: participant)

                enrichedAttendees[key] = EnrichedAttendee(
                    ekParticipantData: ekOnly,
                    contactName: contactInfo?.name,
                    contactEmail: contactInfo?.email,
                    contactOrganization: contactInfo?.organization,
                    contactImageAvailable: contactInfo?.hasImage ?? false,
                    contactFound: contactInfo != nil
                )
            }
        }
    }

    private func lookupContact(for participant: EKParticipant) -> ContactInfo? {
        let predicate = participant.contactPredicate
        let keysToFetch: [CNKeyDescriptor] = [
            CNContactGivenNameKey as CNKeyDescriptor,
            CNContactFamilyNameKey as CNKeyDescriptor,
            CNContactOrganizationNameKey as CNKeyDescriptor,
            CNContactEmailAddressesKey as CNKeyDescriptor,
            CNContactImageDataAvailableKey as CNKeyDescriptor,
        ]

        do {
            let contacts = try contactStore.unifiedContacts(matching: predicate, keysToFetch: keysToFetch)
            guard let contact = contacts.first else { return nil }

            let fullName = [contact.givenName, contact.familyName]
                .filter { !$0.isEmpty }
                .joined(separator: " ")

            let primaryEmail = contact.emailAddresses.first?.value as String?

            return ContactInfo(
                name: fullName.isEmpty ? nil : fullName,
                email: primaryEmail,
                organization: contact.organizationName.isEmpty ? nil : contact.organizationName,
                hasImage: contact.imageDataAvailable
            )
        } catch {
            return nil
        }
    }

    // MARK: - Data Report

    func generateDataReport() -> String {
        var lines: [String] = []
        lines.append("=== EventKitLab Data Availability Report ===")
        lines.append("Generated: \(Date())")
        lines.append("Events: \(snapshots.count)")
        lines.append("")

        for (index, snapshot) in snapshots.enumerated() {
            lines.append("--- Event \(index + 1) ---")
            lines.append("Title: \(snapshot.title)")
            lines.append("Start: \(snapshot.startDate)")
            lines.append("End: \(snapshot.endDate)")
            lines.append("All-day: \(snapshot.isAllDay)")
            lines.append("Calendar: \(snapshot.calendarTitle)")
            lines.append("Calendar Identifier: \(snapshot.calendarIdentifier)")
            lines.append("Calendar Color: \(snapshot.calendarColorHex ?? "n/a")")
            lines.append("Status: \(snapshot.status)")
            lines.append("Availability: \(snapshot.availability)")
            lines.append("Location: \(snapshot.location ?? "n/a")")
            lines.append("URL: \(snapshot.url?.absoluteString ?? "n/a")")
            lines.append("Notes: \(snapshot.notes ?? "n/a")")
            lines.append("TimeZone: \(snapshot.timeZoneIdentifier ?? "n/a")")

            lines.append("Organizer Name: \(snapshot.organizerName ?? "n/a")")
            lines.append("Organizer Email: \(snapshot.organizerEmail ?? "n/a")")
            lines.append("Organizer Is Current User: \(snapshot.organizerIsCurrentUser)")

            lines.append("Conference URL: \(snapshot.conferenceURL?.absoluteString ?? "n/a")")
            lines.append("Conference Platform: \(snapshot.conferencePlatform ?? "n/a")")

            lines.append("Event Identifier: \(snapshot.linkKey.eventIdentifier)")
            lines.append("CalendarItem Identifier: \(snapshot.linkKey.calendarItemIdentifier)")
            lines.append("CalendarItem External ID: \(snapshot.calendarItemExternalIdentifier)")
            lines.append("Occurrence Start: \(snapshot.linkKey.occurrenceStartDate)")

            if snapshot.attendees.isEmpty {
                lines.append("Attendees: none")
            } else {
                lines.append("Attendees (\(snapshot.attendees.count)):")
                for att in snapshot.attendees {
                    lines.append("  - Name: \(att.name ?? "n/a"), Email: \(att.email ?? "n/a"), "
                        + "Role: \(att.role), Status: \(att.status), Type: \(att.type), "
                        + "IsCurrentUser: \(att.isCurrentUser)")
                }
            }

            // Raw EKEvent fields not in snapshot.
            // NOTE: This assumes events[] and snapshots[] stay in sync (same order/count).
            // Production code should look up by identifier rather than positional index.
            if index < events.count {
                let event = events[index]
                lines.append("-- Raw EKEvent extras --")
                lines.append("isDetached: \(event.isDetached)")
                lines.append("birthdayContactIdentifier: \(event.birthdayContactIdentifier ?? "n/a")")

                if let sl = event.structuredLocation {
                    lines.append("StructuredLocation.title: \(sl.title ?? "n/a")")
                    if let geo = sl.geoLocation {
                        lines.append(
                            "StructuredLocation.geoLocation: \(geo.coordinate.latitude), \(geo.coordinate.longitude)"
                        )
                    } else {
                        lines.append("StructuredLocation.geoLocation: n/a")
                    }
                    lines.append("StructuredLocation.radius: \(sl.radius)")
                } else {
                    lines.append("StructuredLocation: n/a")
                }

                lines.append("creationDate: \(event.creationDate?.description ?? "n/a")")
                lines.append("lastModifiedDate: \(event.lastModifiedDate?.description ?? "n/a")")

                if let rules = event.recurrenceRules, !rules.isEmpty {
                    lines.append("Recurrence rules: \(rules.count)")
                    for rule in rules {
                        lines.append("  - \(rule)")
                    }
                } else {
                    lines.append("Recurrence rules: none")
                }

                if let alarms = event.alarms, !alarms.isEmpty {
                    lines.append("Alarms: \(alarms.count)")
                } else {
                    lines.append("Alarms: none")
                }
            }

            lines.append("")
        }

        // Contacts enrichment section
        if !enrichedAttendees.isEmpty {
            lines.append("=== Contacts Enrichment Comparison ===")
            lines.append("Total unique attendees checked: \(enrichedAttendees.count)")
            let found = enrichedAttendees.values.filter(\.contactFound).count
            lines.append("Contacts matches found: \(found) / \(enrichedAttendees.count)")
            lines.append("")

            for (key, enriched) in enrichedAttendees.sorted(by: { $0.key < $1.key }) {
                lines.append("Attendee key: \(key)")
                lines.append("  EK name: \(enriched.ekParticipantData.name ?? "n/a")")
                lines.append("  EK email: \(enriched.ekParticipantData.email ?? "n/a")")
                lines.append("  Contact found: \(enriched.contactFound)")
                if enriched.contactFound {
                    lines.append("  Contact name: \(enriched.contactName ?? "n/a")")
                    lines.append("  Contact email: \(enriched.contactEmail ?? "n/a")")
                    lines.append("  Contact org: \(enriched.contactOrganization ?? "n/a")")
                    lines.append("  Contact has image: \(enriched.contactImageAvailable)")
                }
                lines.append("")
            }
        }

        return lines.joined(separator: "\n")
    }

    func openSystemSettingsCalendar() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Calendars") {
            NSWorkspace.shared.open(url)
        }
    }

    func openSystemSettingsContacts() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Contacts") {
            NSWorkspace.shared.open(url)
        }
    }
}

// MARK: - Contacts enrichment model

struct ContactInfo {
    let name: String?
    let email: String?
    let organization: String?
    let hasImage: Bool
}

struct EnrichedAttendee: Sendable {
    let ekParticipantData: AttendeeSnapshot
    let contactName: String?
    let contactEmail: String?
    let contactOrganization: String?
    let contactImageAvailable: Bool
    let contactFound: Bool
}
