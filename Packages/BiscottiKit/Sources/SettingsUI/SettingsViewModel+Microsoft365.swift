import Foundation
import GraphAuth

// MARK: - Microsoft 365 account (Synderys fork, o365_calendar)

extension SettingsViewModel {
    /// The account state the Settings → Calendars row renders.
    var microsoft365State: GraphAccountState {
        appCore.microsoft365.state
    }

    /// Whether Settings → Permissions shows the Apple Calendar row. Not with
    /// a Microsoft 365 registration, which replaces Apple Calendar as the
    /// calendar source (`AppCore+Live`).
    var showsAppleCalendarPermission: Bool {
        !microsoft365State.isConfigured
    }

    /// Whether there are calendars to list: a Microsoft 365 account (signed
    /// in, or expired with its last sync), or else Apple Calendar access.
    var showsCalendarList: Bool {
        if microsoft365State.isConfigured { return microsoft365State.account != nil }
        return calendarState == .authorized
    }

    /// When Microsoft 365 calendars were last read.
    var microsoft365LastSynced: Date? {
        appCore.microsoft365Calendar?.lastSynced
    }

    static let microsoft365ReadingCaption = "Reading your calendars\u{2026}"
    static let microsoft365NoCalendarsCaption = "No calendars found in this account."

    /// Whether the account's calendars are listed under the row: there is
    /// an account and a sync has read its calendars. Until then the list
    /// could still hold a previous account's calendars.
    var showsMicrosoft365Calendars: Bool {
        microsoft365State.account != nil && microsoft365LastSynced != nil && !calendarGroups.isEmpty
    }

    /// The line under the row while a signed-in account has no list yet.
    var microsoft365CalendarsCaption: String? {
        guard microsoft365State.isSignedIn else { return nil }
        if microsoft365LastSynced == nil { return Self.microsoft365ReadingCaption }
        return calendarGroups.isEmpty ? Self.microsoft365NoCalendarsCaption : nil
    }

    /// The last sign-in, refresh or calendar-read failure, shown in red
    /// under the row.
    var microsoft365Error: String? {
        appCore.microsoft365.lastError ?? appCore.microsoft365Calendar?.syncErrorMessage
    }

    /// Opens the Microsoft sign-in window (Connect and Reconnect).
    func connectMicrosoft365() async {
        await appCore.microsoft365.signIn()
    }

    func cancelMicrosoft365SignIn() {
        appCore.microsoft365.cancelSignIn()
    }

    func disconnectMicrosoft365() async {
        await appCore.microsoft365.signOut()
    }
}
