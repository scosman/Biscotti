/// The pure boundary between store reads and the vocabulary assembly pipeline.
///
/// Every field is a plain value — no SwiftData, no EventKit, no `Bundle`.
/// This is what makes the entire assembly pipeline unit-testable without
/// any external dependencies.
public struct VocabularyInputs: Sendable, Equatable {
    /// The user's stored vocabulary terms, in insertion order.
    public var userTerms: [String]
    /// Whether calendar-derived terms should be included.
    public var calendarEnabled: Bool
    /// The calendar event title, or nil if no snapshot.
    public var eventTitle: String?
    /// The calendar event description/notes, or nil if no snapshot.
    public var eventNotes: String?
    /// Organizer first, then participants. Raw `PersonData.name` values.
    public var attendeeNames: [String]
    /// Raw email addresses from organizer + participants.
    public var attendeeEmails: [String]
    /// Organizer + participants counted before de-duplication.
    public var rawInviteeCount: Int

    public init(
        userTerms: [String] = [],
        calendarEnabled: Bool = false,
        eventTitle: String? = nil,
        eventNotes: String? = nil,
        attendeeNames: [String] = [],
        attendeeEmails: [String] = [],
        rawInviteeCount: Int = 0
    ) {
        self.userTerms = userTerms
        self.calendarEnabled = calendarEnabled
        self.eventTitle = eventTitle
        self.eventNotes = eventNotes
        self.attendeeNames = attendeeNames
        self.attendeeEmails = attendeeEmails
        self.rawInviteeCount = rawInviteeCount
    }
}
