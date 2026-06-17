import SwiftUI

// MARK: - Data model for the picker

/// A lightweight item representing a calendar event in the picker.
/// Decoupled from `CalendarEvent` so the DesignSystem module has no
/// dependency on the Calendar module.
public struct EventPickerItem: Identifiable, Sendable {
    public let id: String
    public let title: String
    public let start: Date
    public let conferencePlatform: String?

    public init(
        id: String,
        title: String,
        start: Date,
        conferencePlatform: String?
    ) {
        self.id = id
        self.title = title
        self.start = start
        self.conferencePlatform = conferencePlatform
    }
}

// MARK: - Shared picker sheet

/// A reusable sheet that lists calendar events near a recording and
/// lets the user pick one (link) or remove the existing association.
///
/// Used by both the meeting-detail overflow menu ("Link/Change Calendar
/// Event") and the recording pane's "Link event" affordance.
public struct EventPickerSheet: View {
    private let events: [EventPickerItem]
    private let hasCalendarAccess: Bool
    private let hasExistingAssociation: Bool
    private let onSelect: (String) -> Void
    private let onRemove: () -> Void
    private let onCancel: () -> Void

    public init(
        events: [EventPickerItem],
        hasCalendarAccess: Bool,
        hasExistingAssociation: Bool,
        onSelect: @escaping (String) -> Void,
        onRemove: @escaping () -> Void,
        onCancel: @escaping () -> Void
    ) {
        self.events = events
        self.hasCalendarAccess = hasCalendarAccess
        self.hasExistingAssociation = hasExistingAssociation
        self.onSelect = onSelect
        self.onRemove = onRemove
        self.onCancel = onCancel
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: Tokens.spacingMD) {
            Text("Choose a calendar event")
                .font(.headline)

            if events.isEmpty {
                if hasCalendarAccess {
                    Text(
                        "No calendar events near this recording\u{2019}s time."
                    )
                    .font(Tokens.metadataFont)
                    .foregroundStyle(.inkSecondary)
                } else {
                    Text(
                        "Calendar access is required to link events. Grant access in System Settings \u{2192} Privacy & Security \u{2192} Calendars."
                    )
                    .font(Tokens.metadataFont)
                    .foregroundStyle(.inkSecondary)
                }
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(events) { event in
                            Button {
                                onSelect(event.id)
                            } label: {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(event.title)
                                        .font(.body)
                                    HStack {
                                        Text(Self.formatEventTime(event))
                                            .font(.monoMeta)
                                            .foregroundStyle(
                                                Tokens.secondaryText
                                            )
                                        if let platform =
                                            event.conferencePlatform
                                        {
                                            Text(platform)
                                                .font(.caption2)
                                                .foregroundStyle(
                                                    Tokens.secondaryText
                                                )
                                        }
                                    }
                                }
                                .padding(.vertical, Tokens.spacingXS)
                                .frame(
                                    maxWidth: .infinity,
                                    alignment: .leading
                                )
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
                .frame(maxHeight: 300)
            }

            Divider()

            HStack {
                if hasExistingAssociation {
                    Button("Remove association") {
                        onRemove()
                    }
                    .foregroundStyle(.signalRed)
                }
                Spacer()
                Button("Cancel") { onCancel() }
            }
        }
        .padding(Tokens.spacingLG)
        .frame(minWidth: 350)
    }

    private static let timeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .short
        formatter.timeStyle = .short
        return formatter
    }()

    private static func formatEventTime(_ event: EventPickerItem) -> String {
        timeFormatter.string(from: event.start)
    }
}
