import SwiftUI

/// Displays calendar context for a meeting: conference platform/join link,
/// calendar name + color dot, organizer, attendees, and a Change button
/// for association correction.
///
/// Value-type inputs only -- no view model.
public struct CalendarContextBlock: View {
    private let platform: String?
    private let conferenceURL: URL?
    private let calendarTitle: String?
    private let calendarColorHex: String?
    private let location: String?
    private let organizer: String?
    private let attendees: [String]
    private let onJoin: (() -> Void)?
    private let onChange: (() -> Void)?

    public init(
        platform: String?,
        conferenceURL: URL?,
        calendarTitle: String?,
        calendarColorHex: String?,
        location: String?,
        organizer: String?,
        attendees: [String],
        onJoin: (() -> Void)?,
        onChange: (() -> Void)?
    ) {
        self.platform = platform
        self.conferenceURL = conferenceURL
        self.calendarTitle = calendarTitle
        self.calendarColorHex = calendarColorHex
        self.location = location
        self.organizer = organizer
        self.attendees = attendees
        self.onJoin = onJoin
        self.onChange = onChange
    }

    public var body: some View {
        HStack(alignment: .top, spacing: Tokens.spacingSM) {
            Image(systemName: "calendar")
                .foregroundStyle(Tokens.secondaryText)
                .font(.callout)
                .padding(.top, 2)

            VStack(alignment: .leading, spacing: Tokens.spacingSM) {
                // Top row: platform + calendar badge + actions
                HStack {
                    if let platform {
                        Text(platform)
                            .font(.callout.weight(.medium))
                    }

                    if let calendarTitle {
                        HStack(spacing: 4) {
                            Circle()
                                .fill(calendarColor)
                                .frame(width: 8, height: 8)
                            Text(calendarTitle)
                                .font(.caption)
                                .foregroundStyle(Tokens.secondaryText)
                        }
                    }

                    Spacer()

                    if let onJoin, conferenceURL != nil {
                        Button("Join") { onJoin() }
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                    }

                    if let onChange {
                        Button("Change\u{2026}") { onChange() }
                            .buttonStyle(.borderless)
                            .controlSize(.small)
                    }
                }

                // Location (if different from conference URL)
                if let location, !location.isEmpty {
                    Text(location)
                        .font(.caption)
                        .foregroundStyle(Tokens.secondaryText)
                        .lineLimit(1)
                }

                // Participants
                if organizer != nil || !attendees.isEmpty {
                    HStack(spacing: Tokens.spacingXS) {
                        if let organizer {
                            Text("\(organizer) (organizer)")
                                .font(.caption)
                        }
                        ForEach(attendees, id: \.self) { name in
                            Text(name)
                                .font(.caption)
                        }
                    }
                    .foregroundStyle(Tokens.secondaryText)
                    .lineLimit(1)
                }
            }
        }
        .padding(Tokens.spacingSM)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(Color.secondary.opacity(0.06))
        )
    }

    private var calendarColor: Color {
        guard let hex = calendarColorHex else { return .gray }
        return Color(hex: hex)
    }
}

// MARK: - Color hex initializer

public extension Color {
    /// Creates a Color from a `#RRGGBB` hex string.
    init(hex: String) {
        let cleaned = hex.trimmingCharacters(in: CharacterSet(charactersIn: "#"))
        guard cleaned.count == 6,
              let value = UInt64(cleaned, radix: 16)
        else {
            self = .gray
            return
        }
        let red = Double((value >> 16) & 0xFF) / 255.0
        let green = Double((value >> 8) & 0xFF) / 255.0
        let blue = Double(value & 0xFF) / 255.0
        self.init(red: red, green: green, blue: blue)
    }
}

#Preview("Calendar Context Block") {
    VStack(spacing: 16) {
        CalendarContextBlock(
            platform: "Zoom",
            conferenceURL: URL(string: "https://zoom.us/j/123"),
            calendarTitle: "Work",
            calendarColorHex: "#0066CC",
            location: nil,
            organizer: "Sam Lee",
            attendees: ["You", "Alex Kim"],
            onJoin: {},
            onChange: {}
        )
        CalendarContextBlock(
            platform: nil,
            conferenceURL: nil,
            calendarTitle: "Personal",
            calendarColorHex: "#33CC33",
            location: "Conference Room B",
            organizer: nil,
            attendees: ["Bob", "Carol"],
            onJoin: nil,
            onChange: {}
        )
    }
    .padding()
    .frame(width: 400)
}
