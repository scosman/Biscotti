import EventKit
import SwiftUI

struct PermissionView: View {
    let manager: CalendarAccessManager

    var body: some View {
        VStack(spacing: 20) {
            Text("Calendar & Contacts Access")
                .font(.title)

            GroupBox("Calendar Access") {
                VStack(alignment: .leading, spacing: 12) {
                    HStack {
                        statusIcon(for: manager.hasCalendarAccess)
                        Text("Status: \(calendarStatusText)")
                            .font(.headline)
                    }

                    Text(calendarStatusDetail)
                        .foregroundStyle(.secondary)

                    HStack {
                        if manager.calendarAuthStatus == .notDetermined {
                            Button("Request Calendar Access") {
                                Task { await manager.requestCalendarAccess() }
                            }
                            .buttonStyle(.borderedProminent)
                        }

                        if manager.calendarAuthStatus == .denied
                            || manager.calendarAuthStatus == .restricted
                            || manager.calendarAuthStatus == .writeOnly
                        {
                            Button("Open System Settings") {
                                manager.openSystemSettingsCalendar()
                            }
                        }
                    }
                }
                .padding(8)
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            GroupBox("Contacts Access") {
                VStack(alignment: .leading, spacing: 12) {
                    HStack {
                        statusIcon(for: manager.hasContactsAccess)
                        Text("Status: \(contactsStatusText)")
                            .font(.headline)
                    }

                    Text("Contacts access is used to enrich attendee information and compare with EKParticipant data.")
                        .foregroundStyle(.secondary)

                    HStack {
                        if manager.contactsAuthStatus == .notDetermined {
                            Button("Request Contacts Access") {
                                Task { await manager.requestContactsAccess() }
                            }
                            .buttonStyle(.borderedProminent)
                        }

                        if manager.contactsAuthStatus == .denied
                            || manager.contactsAuthStatus == .restricted
                        {
                            Button("Open System Settings") {
                                manager.openSystemSettingsContacts()
                            }
                        }
                    }
                }
                .padding(8)
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            if let error = manager.errorMessage {
                Text(error)
                    .foregroundStyle(.red)
                    .padding()
            }

            Spacer()
        }
        .padding()
        .task {
            await manager.requestCalendarAccess()
        }
    }

    private var calendarStatusText: String {
        switch manager.calendarAuthStatus {
        case .notDetermined: "Not Determined"
        case .fullAccess: "Full Access"
        case .authorized: "Authorized (deprecated)"
        case .writeOnly: "Write Only (insufficient)"
        case .denied: "Denied"
        case .restricted: "Restricted"
        @unknown default: "Unknown"
        }
    }

    private var calendarStatusDetail: String {
        switch manager.calendarAuthStatus {
        case .notDetermined:
            "Click the button below to request calendar access."
        case .fullAccess, .authorized:
            "Calendar access granted. You can view calendars and events in the other tabs."
        case .writeOnly:
            "Only write access was granted. Full access (read) is required. Please grant full access in System Settings."
        case .denied:
            "Calendar access was denied. Please enable it in System Settings > Privacy & Security > Calendars."
        case .restricted:
            "Calendar access is restricted by device policy."
        @unknown default:
            "Unknown authorization status."
        }
    }

    private var contactsStatusText: String {
        switch manager.contactsAuthStatus {
        case .notDetermined: "Not Determined"
        case .authorized: "Authorized"
        case .denied: "Denied"
        case .restricted: "Restricted"
        @unknown default: "Unknown"
        }
    }

    @ViewBuilder
    private func statusIcon(for granted: Bool) -> some View {
        Image(systemName: granted ? "checkmark.circle.fill" : "xmark.circle.fill")
            .foregroundStyle(granted ? .green : .orange)
            .font(.title2)
    }
}
