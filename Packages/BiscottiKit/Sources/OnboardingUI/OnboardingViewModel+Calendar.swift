import Calendar

// MARK: - Calendar selection helpers

public extension OnboardingViewModel {
    /// Whether a calendar is enabled (checked).
    func isCalendarEnabled(_ calendarID: String) -> Bool {
        guard let enabled = enabledCalendarIDs else { return true }
        return enabled.contains(calendarID)
    }

    /// Toggle a calendar on/off. Persists to settings.
    func toggleCalendar(_ calendarID: String) async {
        let allIDs = calendarGroups
            .flatMap(\.calendars)
            .map(\.id)

        var newSet: Set<String>
        if let current = enabledCalendarIDs {
            newSet = current
            if newSet.contains(calendarID) {
                newSet.remove(calendarID)
            } else {
                newSet.insert(calendarID)
            }
        } else {
            newSet = Set(allIDs)
            newSet.remove(calendarID)
        }

        if newSet.count == allIDs.count {
            enabledCalendarIDs = nil
        } else {
            enabledCalendarIDs = newSet
        }

        do {
            let updated = enabledCalendarIDs
            try await appCore.store.updateSettings { settings in
                settings.enabledCalendarIDs = updated
            }
        } catch {
            // Revert on failure
            enabledCalendarIDs = nil
        }
    }

    /// Groups CalendarInfo items by sourceTitle (same logic as SettingsVM).
    static func groupCalendars(
        _ infos: [CalendarInfo]
    ) -> [OnboardingCalendarGroup] {
        let grouped = Dictionary(grouping: infos, by: \.sourceTitle)
        return grouped
            .sorted { $0.key < $1.key }
            .map { source, calendars in
                OnboardingCalendarGroup(
                    id: source,
                    sourceTitle: source,
                    calendars: calendars.sorted { $0.title < $1.title }
                )
            }
    }
}
