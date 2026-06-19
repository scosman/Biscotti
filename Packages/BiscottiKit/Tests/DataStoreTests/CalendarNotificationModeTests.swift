import DataStore
import Testing

@Suite("CalendarNotificationMode")
struct CalendarNotificationModeTests {
    @Test("rawValue stability")
    func rawValueStability() {
        #expect(CalendarNotificationMode.allMeetings.rawValue == "allMeetings")
        #expect(CalendarNotificationMode.videoConferencing.rawValue == "videoConferencing")
        #expect(CalendarNotificationMode.never.rawValue == "never")
    }

    @Test("displayText for each case")
    func displayText() {
        #expect(CalendarNotificationMode.allMeetings.displayText == "All Meetings")
        #expect(CalendarNotificationMode.videoConferencing.displayText == "Meetings with Video Conferencing")
        #expect(CalendarNotificationMode.never.displayText == "Never")
    }

    @Test("allCases has three entries")
    func allCasesCount() {
        #expect(CalendarNotificationMode.allCases.count == 3)
    }

    @Test("init(raw:) returns correct case for known values")
    func initRawKnown() {
        #expect(CalendarNotificationMode(raw: "allMeetings") == .allMeetings)
        #expect(CalendarNotificationMode(raw: "videoConferencing") == .videoConferencing)
        #expect(CalendarNotificationMode(raw: "never") == .never)
    }

    @Test("init(raw:) defaults to .allMeetings for unknown values")
    func initRawUnknown() {
        // This initializer is also the store's defense: settings() uses
        // CalendarNotificationMode(raw:) to map the SwiftData raw string,
        // so unknown values gracefully fall back to .allMeetings.
        #expect(CalendarNotificationMode(raw: "bogus") == .allMeetings)
        #expect(CalendarNotificationMode(raw: "") == .allMeetings)
    }

    @Test("id is rawValue")
    func idIsRawValue() {
        for mode in CalendarNotificationMode.allCases {
            #expect(mode.id == mode.rawValue)
        }
    }
}

@Suite("DataStore -- notification settings round-trip")
struct NotificationSettingsRoundTripTests {
    @Test("settings defaults include notification fields")
    func defaultsIncludeNotificationFields() async throws {
        let store = try DataStore(storage: .inMemory)
        let settings = try await store.settings()
        #expect(settings.monitorForMeetings == true)
        #expect(settings.stopRecordingAutomatically == true)
        #expect(settings.calendarNotificationMode == .allMeetings)
    }

    @Test("updateSettings persists notification fields")
    func updateSettingsPersists() async throws {
        let store = try DataStore(storage: .inMemory)
        try await store.updateSettings { settings in
            settings.monitorForMeetings = false
            settings.stopRecordingAutomatically = false
            settings.calendarNotificationMode = .videoConferencing
        }

        let result = try await store.settings()
        #expect(result.monitorForMeetings == false)
        #expect(result.stopRecordingAutomatically == false)
        #expect(result.calendarNotificationMode == .videoConferencing)
    }

    @Test("calendarNotificationMode .never round-trips")
    func calendarModeNeverRoundTrips() async throws {
        let store = try DataStore(storage: .inMemory)
        try await store.updateSettings { settings in
            settings.calendarNotificationMode = .never
        }
        let result = try await store.settings()
        #expect(result.calendarNotificationMode == .never)
    }

    @Test("store round-trip: write via DTO then read back preserves mode")
    func storeDTORoundTrip() async throws {
        let store = try DataStore(storage: .inMemory)
        // Write each mode through the DTO path and read it back.
        for mode in CalendarNotificationMode.allCases {
            try await store.updateSettings { settings in
                settings.calendarNotificationMode = mode
            }
            let result = try await store.settings()
            #expect(result.calendarNotificationMode == mode)
        }
    }
}
