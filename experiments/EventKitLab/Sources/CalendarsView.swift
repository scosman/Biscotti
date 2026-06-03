import EventKit
import SwiftUI

struct CalendarsView: View {
    let manager: CalendarAccessManager

    var body: some View {
        VStack(spacing: 12) {
            Text("Calendar Filter")
                .font(.title)

            if !manager.hasCalendarAccess {
                Text("Calendar access not granted. Go to the Permission tab first.")
                    .foregroundStyle(.secondary)
                    .padding()
                Spacer()
            } else if manager.calendars.isEmpty {
                Text("No calendars found.")
                    .foregroundStyle(.secondary)
                    .padding()
                Spacer()
            } else {
                HStack {
                    Button("Enable All") {
                        var ids = manager.enabledCalendarIDs
                        for cal in manager.calendars {
                            ids.insert(cal.calendarIdentifier)
                        }
                        manager.enabledCalendarIDs = ids
                    }
                    Button("Disable All") {
                        manager.enabledCalendarIDs = []
                    }
                    Spacer()
                    Button("Refresh") {
                        manager.loadCalendars()
                    }
                }
                .padding(.horizontal)

                List {
                    ForEach(calendarsBySource, id: \.source) { group in
                        Section(header: Text(group.source)) {
                            ForEach(group.calendars, id: \.calendarIdentifier) { calendar in
                                CalendarRow(
                                    calendar: calendar,
                                    isEnabled: manager.isCalendarEnabled(calendar),
                                    onToggle: { manager.toggleCalendar(calendar) }
                                )
                            }
                        }
                    }
                }
            }
        }
        .padding()
        .onAppear {
            manager.loadCalendars()
        }
    }

    private var calendarsBySource: [CalendarGroup] {
        let grouped = Dictionary(grouping: manager.calendars) { $0.source?.title ?? "Unknown" }
        return grouped.map { CalendarGroup(source: $0.key, calendars: $0.value) }
            .sorted { $0.source < $1.source }
    }
}

private struct CalendarGroup {
    let source: String
    let calendars: [EKCalendar]
}

private struct CalendarRow: View {
    let calendar: EKCalendar
    let isEnabled: Bool
    let onToggle: () -> Void

    var body: some View {
        HStack {
            Circle()
                .fill(Color(cgColor: calendar.cgColor))
                .frame(width: 12, height: 12)
            Text(calendar.title)
            Spacer()
            Text(calendarTypeLabel)
                .font(.caption)
                .foregroundStyle(.secondary)
            Toggle("", isOn: Binding(
                get: { isEnabled },
                set: { _ in onToggle() }
            ))
            .labelsHidden()
        }
    }

    private var calendarTypeLabel: String {
        switch calendar.type {
        case .local: "Local"
        case .calDAV: "CalDAV"
        case .exchange: "Exchange"
        case .subscription: "Subscription"
        case .birthday: "Birthday"
        @unknown default: "Other"
        }
    }
}
