import Calendar
import DesignSystem
import Permissions
import SwiftUI

// MARK: - Calendar section (extracted for type_body_length)

extension SettingsView {
    var calendarSection: some View {
        Section(Self.sectionTitles[6]) {
            if viewModel.microsoft365State.isConfigured {
                microsoft365Calendars
            } else if viewModel.calendarState == .authorized {
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
        .onChange(of: viewModel.microsoft365LastSynced) {
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

// MARK: - Microsoft 365 (Synderys fork, o365_calendar)

extension SettingsView {
    /// With an app registration, Microsoft 365 replaces Apple Calendar: the
    /// account row, then the account's calendars (including shared ones
    /// added in Outlook) in the same include/exclude list.
    @ViewBuilder
    var microsoft365Calendars: some View {
        Microsoft365AccountRow(viewModel: viewModel)
        if let caption = viewModel.microsoft365CalendarsCaption {
            Text(caption)
                .font(Tokens.metadataFont)
                .foregroundStyle(Tokens.secondaryText)
        } else if viewModel.showsMicrosoft365Calendars {
            ForEach(viewModel.calendarGroups) { group in
                Section(header: Text(group.sourceTitle)) {
                    ForEach(group.calendars) { cal in
                        calendarRow(cal)
                    }
                }
            }
        }
    }
}
