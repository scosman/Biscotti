import Calendar
import DesignSystem
import Permissions
import SwiftUI

// MARK: - Calendar section (extracted for type_body_length)

extension SettingsView {
    var calendarSection: some View {
        Section(Self.sectionTitles[4]) {
            if viewModel.calendarState == .authorized {
                if viewModel.calendarGroups.isEmpty {
                    settingsCalendarEmptyState
                } else {
                    ForEach(viewModel.calendarGroups) { group in
                        Section(header: Text(group.sourceTitle)) {
                            ForEach(group.calendars) { cal in
                                calendarRow(cal)
                            }
                        }
                    }

                    MissingCalendarsHint(onMoreInfo: {
                        showConnectCalendar = true
                    })
                }
            } else {
                Text("Calendar access not granted.")
                    .font(Tokens.metadataFont)
                    .foregroundStyle(Tokens.secondaryText)
                permissionActionButton(
                    state: viewModel.calendarState,
                    kind: .calendar
                )
            }
        }
        .sheet(isPresented: $showConnectCalendar) {
            ConnectCalendarSheet()
        }
        .onReceive(
            NotificationCenter.default.publisher(
                for: NSApplication.didBecomeActiveNotification
            )
        ) { _ in
            Task { await viewModel.reloadCalendars() }
        }
    }

    /// Lighter empty state for Settings: headline + one line + "More info",
    /// fitting the grouped Form aesthetic without the big icon tile.
    var settingsCalendarEmptyState: some View {
        VStack(alignment: .leading, spacing: Tokens.spacingXS) {
            Text("No calendars found")
                .font(.headline)

            Text(
                "If you use Google Calendar in the browser, add your account to the Mac\u{2019}s Calendar app."
            )
            .font(Tokens.metadataFont)
            .foregroundStyle(Tokens.secondaryText)

            MoreInfoLink(action: {
                showConnectCalendar = true
            })
            .padding(.top, 2)
        }
    }
}
