import GraphAuth

// MARK: - Microsoft 365 (Synderys fork, o365_calendar)

public extension OnboardingViewModel {
    /// Whether Microsoft 365 is the calendar source (`AppCore+Live`): the
    /// Grant access card shows a Connect row for it instead of the Calendar
    /// permission.
    var usesMicrosoft365: Bool {
        microsoft365State.isConfigured
    }

    var microsoft365State: GraphAccountState {
        appCore.microsoft365.state
    }

    /// The last sign-in or calendar-read failure, under the row.
    var microsoft365Error: String? {
        appCore.microsoft365.lastError ?? appCore.microsoft365Calendar?.syncErrorMessage
    }

    static let microsoft365NoCalendarsMessage =
        "Your Microsoft 365 account has no calendars Biscotti can read. "
            + "You can check again later in Settings \u{2192} Calendars."

    /// The body of the calendar step's empty state: why nothing was read,
    /// or that the account has no calendars.
    var microsoft365EmptyCalendarsMessage: String {
        appCore.microsoft365Calendar?.syncErrorMessage ?? Self.microsoft365NoCalendarsMessage
    }

    /// Opens the Microsoft sign-in window (Connect and Reconnect).
    func connectMicrosoft365() async {
        await appCore.microsoft365.signIn()
    }

    func cancelMicrosoft365SignIn() {
        appCore.microsoft365.cancelSignIn()
    }
}
