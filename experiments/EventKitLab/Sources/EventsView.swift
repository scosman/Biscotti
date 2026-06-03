import SwiftUI

struct EventsView: View {
    let manager: CalendarAccessManager

    @State private var startDate = Calendar.current.date(byAdding: .day, value: -1, to: Date()) ?? Date()
    @State private var endDate = Calendar.current.date(byAdding: .day, value: 7, to: Date()) ?? Date()
    @State private var selectedEventID: String?
    @State private var showEnrichment = false

    var body: some View {
        VStack(spacing: 12) {
            Text("Events")
                .font(.title)

            if !manager.hasCalendarAccess {
                Text("Calendar access not granted. Go to the Permission tab first.")
                    .foregroundStyle(.secondary)
                Spacer()
            } else {

            HStack {
                DatePicker("From:", selection: $startDate, displayedComponents: .date)
                DatePicker("To:", selection: $endDate, displayedComponents: .date)
                Button("Fetch Events") {
                    manager.fetchEvents(from: startDate, to: endDate)
                }
                .buttonStyle(.borderedProminent)
            }
            .padding(.horizontal)

            HStack {
                Text("\(manager.snapshots.count) events loaded")
                    .foregroundStyle(.secondary)
                Spacer()
                if manager.hasContactsAccess {
                    Button(showEnrichment ? "Hide Contacts Comparison" : "Show Contacts Comparison") {
                        if !showEnrichment {
                            manager.enrichAttendeesWithContacts()
                        }
                        showEnrichment.toggle()
                    }
                } else {
                    Button("Request Contacts Access for Enrichment") {
                        Task {
                            await manager.requestContactsAccess()
                        }
                    }
                    .font(.caption)
                }
            }
            .padding(.horizontal)

            if manager.snapshots.isEmpty {
                Text("No events in the selected range. Try adjusting the date range or enabling more calendars.")
                    .foregroundStyle(.secondary)
                    .padding()
                Spacer()
            } else {
                List(selection: $selectedEventID) {
                    ForEach(manager.snapshots) { snapshot in
                        EventRow(
                            snapshot: snapshot,
                            enrichedAttendees: showEnrichment ? manager.enrichedAttendees : [:],
                            isExpanded: selectedEventID == snapshot.id
                        )
                        .tag(snapshot.id)
                        .contentShape(Rectangle())
                        .onTapGesture {
                            if selectedEventID == snapshot.id {
                                selectedEventID = nil
                            } else {
                                selectedEventID = snapshot.id
                            }
                        }
                    }
                }
            }

            } // else hasCalendarAccess
        }
        .padding()
    }
}

private struct EventRow: View {
    let snapshot: CalendarEventSnapshot
    let enrichedAttendees: [String: EnrichedAttendee]
    let isExpanded: Bool

    private static let timeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .medium
        f.timeStyle = .short
        return f
    }()

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                if let hex = snapshot.calendarColorHex {
                    Circle()
                        .fill(Color(hex: hex))
                        .frame(width: 10, height: 10)
                }
                Text(snapshot.title)
                    .font(.headline)
                Spacer()
                if snapshot.isAllDay {
                    Text("All Day")
                        .font(.caption)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(.quaternary)
                        .clipShape(RoundedRectangle(cornerRadius: 4))
                }
                if snapshot.conferencePlatform != nil {
                    Image(systemName: "video.fill")
                        .foregroundStyle(.blue)
                }
            }

            HStack {
                Text(Self.timeFormatter.string(from: snapshot.startDate))
                Text("-")
                Text(Self.timeFormatter.string(from: snapshot.endDate))
            }
            .font(.subheadline)
            .foregroundStyle(.secondary)

            Text("Calendar: \(snapshot.calendarTitle)")
                .font(.caption)
                .foregroundStyle(.secondary)

            if isExpanded {
                expandedContent
            }
        }
        .padding(.vertical, 4)
    }

    @ViewBuilder
    private var expandedContent: some View {
        Divider()
        VStack(alignment: .leading, spacing: 8) {
            if let organizer = snapshot.organizerName {
                LabeledField(label: "Organizer", value: "\(organizer)\(snapshot.organizerEmail.map { " (\($0))" } ?? "")\(snapshot.organizerIsCurrentUser ? " [You]" : "")")
            }

            if let location = snapshot.location {
                LabeledField(label: "Location", value: location)
            }

            if let url = snapshot.url {
                LabeledField(label: "URL", value: url.absoluteString)
            }

            if let confURL = snapshot.conferenceURL, let platform = snapshot.conferencePlatform {
                LabeledField(label: "Conference", value: "\(platform.capitalized): \(confURL.absoluteString)")
            }

            if let notes = snapshot.notes, !notes.isEmpty {
                VStack(alignment: .leading) {
                    Text("Notes:").font(.caption).bold()
                    Text(notes)
                        .font(.caption)
                        .lineLimit(5)
                }
            }

            LabeledField(label: "Status", value: snapshot.status)
            LabeledField(label: "Availability", value: snapshot.availability)

            if let tz = snapshot.timeZoneIdentifier {
                LabeledField(label: "TimeZone", value: tz)
            }

            if !snapshot.attendees.isEmpty {
                Text("Attendees (\(snapshot.attendees.count)):").font(.caption).bold()
                ForEach(snapshot.attendees) { attendee in
                    AttendeeRow(
                        attendee: attendee,
                        enriched: findEnriched(for: attendee)
                    )
                }
            }

            LabeledField(label: "Event ID", value: snapshot.linkKey.eventIdentifier)
            LabeledField(label: "External ID", value: snapshot.calendarItemExternalIdentifier)
        }
        .padding(.leading, 8)
    }

    private func findEnriched(for attendee: AttendeeSnapshot) -> EnrichedAttendee? {
        enrichedAttendees[attendee.enrichmentKey]
    }
}

private struct AttendeeRow: View {
    let attendee: AttendeeSnapshot
    let enriched: EnrichedAttendee?

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text(attendee.name ?? "(no name)")
                    .font(.caption)
                if let email = attendee.email {
                    Text("(\(email))")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                if attendee.isCurrentUser {
                    Text("[You]")
                        .font(.caption2)
                        .foregroundStyle(.blue)
                }
            }
            HStack {
                Text("Role: \(attendee.role)")
                Text("Status: \(attendee.status)")
                Text("Type: \(attendee.type)")
            }
            .font(.caption2)
            .foregroundStyle(.secondary)

            if let enriched {
                VStack(alignment: .leading, spacing: 1) {
                    Text("-- Contacts enrichment --")
                        .font(.caption2)
                        .foregroundStyle(.purple)
                    if enriched.contactFound {
                        if let name = enriched.contactName {
                            Text("Contact name: \(name)")
                        }
                        if let email = enriched.contactEmail {
                            Text("Contact email: \(email)")
                        }
                        if let org = enriched.contactOrganization {
                            Text("Contact org: \(org)")
                        }
                        Text("Has photo: \(enriched.contactImageAvailable ? "Yes" : "No")")
                    } else {
                        Text("No matching contact found")
                    }
                }
                .font(.caption2)
                .foregroundStyle(.purple)
            }
        }
        .padding(.leading, 12)
    }
}

private struct LabeledField: View {
    let label: String
    let value: String

    var body: some View {
        HStack(alignment: .top) {
            Text("\(label):")
                .font(.caption)
                .bold()
                .frame(width: 90, alignment: .trailing)
            Text(value)
                .font(.caption)
                .textSelection(.enabled)
        }
    }
}

// MARK: - Color from hex

extension Color {
    init(hex: String) {
        let hex = hex.trimmingCharacters(in: CharacterSet(charactersIn: "#"))
        let scanner = Scanner(string: hex)
        var rgb: UInt64 = 0
        scanner.scanHexInt64(&rgb)
        let r = Double((rgb >> 16) & 0xFF) / 255.0
        let g = Double((rgb >> 8) & 0xFF) / 255.0
        let b = Double(rgb & 0xFF) / 255.0
        self.init(red: r, green: g, blue: b)
    }
}
