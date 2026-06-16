import SwiftUI

/// Value-typed data for the calendar info card. Mapped by the view model
/// from `CalendarContextData` so DesignSystem does not depend on DataStore.
public struct CalendarCardData: Sendable, Equatable {
    public var attendees: [AvatarPerson]
    public var attendeeTotal: Int
    public var summary: AttributedString
    public var whenText: String?
    public var platform: String?
    public var conferenceURL: URL?
    public var location: String?
    public var eventNotes: String?
    public var invitedText: String?

    public init(
        attendees: [AvatarPerson],
        attendeeTotal: Int,
        summary: AttributedString,
        whenText: String? = nil,
        platform: String? = nil,
        conferenceURL: URL? = nil,
        location: String? = nil,
        eventNotes: String? = nil,
        invitedText: String? = nil
    ) {
        self.attendees = attendees
        self.attendeeTotal = attendeeTotal
        self.summary = summary
        self.whenText = whenText
        self.platform = platform
        self.conferenceURL = conferenceURL
        self.location = location
        self.eventNotes = eventNotes
        self.invitedText = invitedText
    }
}

/// A rounded card showing calendar event context for a linked meeting.
///
/// Row A: attendee avatar stack + summary + "Open in Calendar" button.
/// Row B: custom disclosure with tappable header (whole row toggles).
///        Collapsed: "Event Details" + WHEN preview line.
///        Expanded: definition list (WHEN / WHERE / INVITED / DESCRIPTION)
///        with selectable/copyable values.
public struct CalendarInfoCard: View {
    let data: CalendarCardData
    let onOpenInCalendar: () -> Void
    @State private var expanded = false

    public init(
        data: CalendarCardData,
        onOpenInCalendar: @escaping () -> Void
    ) {
        self.data = data
        self.onOpenInCalendar = onOpenInCalendar
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            rowA
            Divider()
                .overlay(Color.hairline)
                .padding(.vertical, Tokens.spacingSM)
            rowB
        }
        .padding(Tokens.spacingMD)
        .background(
            RoundedRectangle(cornerRadius: Tokens.cardRadius)
                .fill(Tokens.cardFill)
        )
        .overlay(
            RoundedRectangle(cornerRadius: Tokens.cardRadius)
                .strokeBorder(Color.cardStroke, lineWidth: 0.5)
        )
    }

    // MARK: - Row A

    private var rowA: some View {
        HStack(spacing: Tokens.spacingSM) {
            if data.attendeeTotal > 0 {
                AvatarCluster(
                    people: data.attendees,
                    totalCount: data.attendeeTotal,
                    size: Tokens.avatarSize
                )
            }

            Text(data.summary)
                .font(.system(size: 13))
                .lineLimit(1)

            Spacer()

            Button {
                onOpenInCalendar()
            } label: {
                Label {
                    Text("Open in Calendar")
                        .foregroundStyle(.ink)
                } icon: {
                    Image(systemName: "calendar")
                        .foregroundStyle(.inkSecondary)
                }
            }
            .buttonStyle(.borderless)
            .controlSize(.small)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(
                Tokens.neutralChip,
                in: RoundedRectangle(cornerRadius: Tokens.buttonRadius)
            )
        }
    }

    // MARK: - Row B: custom tappable disclosure

    private var rowB: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Tappable header -- whole line toggles expansion
            Button {
                withAnimation {
                    expanded.toggle()
                }
            } label: {
                HStack(spacing: Tokens.spacingSM) {
                    // Rotating chevron (mirrors stock DisclosureGroup)
                    Image(systemName: "chevron.right")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.inkSecondary)
                        .rotationEffect(.degrees(expanded ? 90 : 0))
                        .animation(.default, value: expanded)

                    Text("Event Details")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(.ink)

                    // Collapsed preview: show WHEN content
                    if !expanded, let when = data.whenText {
                        Text(when)
                            .font(.monoMeta)
                            .foregroundStyle(.inkSecondary)
                            .lineLimit(1)
                            .truncationMode(.tail)
                    }

                    Spacer()
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityAddTraits(.isButton)
            .accessibilityValue(expanded ? "expanded" : "collapsed")

            if expanded {
                definitionList
                    .padding(.top, Tokens.spacingSM)
            }
        }
    }

    // MARK: - Definition list

    private var definitionList: some View {
        Grid(
            alignment: .leadingFirstTextBaseline,
            horizontalSpacing: 16,
            verticalSpacing: 11
        ) {
            if let when = data.whenText {
                GridRow {
                    Text("WHEN")
                        .kicker()
                        .foregroundStyle(.inkTertiary)
                        .gridColumnAlignment(.leading)
                    Text(when)
                        .font(.monoMeta)
                        .foregroundStyle(.ink)
                        .textSelection(.enabled)
                }
            }

            if data.platform != nil || data.location != nil {
                GridRow {
                    Text("WHERE")
                        .kicker()
                        .foregroundStyle(.inkTertiary)
                    whereContent
                }
            }

            if let invited = data.invitedText {
                GridRow {
                    Text("INVITED")
                        .kicker()
                        .foregroundStyle(.inkTertiary)
                    Text(invited)
                        .font(.system(size: 13))
                        .foregroundStyle(.ink)
                        .textSelection(.enabled)
                }
            }

            if let notes = data.eventNotes, !notes.isEmpty {
                GridRow {
                    Text("DESCRIPTION")
                        .kicker()
                        .foregroundStyle(.inkTertiary)
                    Text(notes)
                        .font(.system(size: 13))
                        .foregroundStyle(.inkSecondary)
                        .frame(maxWidth: 460, alignment: .leading)
                        .textSelection(.enabled)
                }
            }
        }
    }

    private var whereContent: some View {
        VStack(alignment: .leading, spacing: 4) {
            if let platform = data.platform {
                HStack(spacing: 4) {
                    Image(systemName: "video.fill")
                        .foregroundStyle(.sage)
                        .font(.system(size: 10))
                    Text(platform)
                        .font(.system(size: 13))
                        .foregroundStyle(.ink)
                    if let url = data.conferenceURL {
                        Text(url.absoluteString)
                            .font(.monoMeta)
                            .foregroundStyle(.inkSecondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .textSelection(.enabled)
                    }
                }
            }
            if let location = data.location, !location.isEmpty {
                Text(location)
                    .font(.system(size: 13))
                    .foregroundStyle(.inkSecondary)
                    .textSelection(.enabled)
            }
        }
    }
}

// MARK: - Previews

#Preview("CalendarInfoCard") {
    let sampleData = CalendarCardData(
        attendees: [
            AvatarPerson(displayName: "Steve Jobs", email: "steve@apple.com"),
            AvatarPerson(displayName: "Alex Kim", email: "alex@example.com"),
            AvatarPerson(displayName: "Jay Park", email: "jay@example.com")
        ],
        attendeeTotal: 5,
        summary: {
            var name = AttributedString("Steve Jobs")
            name.font = .system(size: 13, weight: .medium)
            name.foregroundColor = .ink
            var rest = AttributedString(", Alex Kim, and 2 others")
            rest.font = .system(size: 13)
            rest.foregroundColor = .inkSecondary
            return name + rest
        }(),
        whenText: "Yesterday, Jun 11 \u{00B7} 4:18 \u{2013} 4:50 PM",
        platform: "Google Meet",
        conferenceURL: URL(string: "https://meet.google.com/abc-defg-hij"),
        location: nil,
        eventNotes: "Quarterly retention review and product deep dive for Q2 metrics.",
        invitedText: "Steve (organizer) \u{00B7} Alex \u{00B7} Jay \u{00B7} +2"
    )

    CalendarInfoCard(data: sampleData, onOpenInCalendar: {})
        .frame(width: 700)
        .padding()
        .background(Tokens.contentBackground)
}
