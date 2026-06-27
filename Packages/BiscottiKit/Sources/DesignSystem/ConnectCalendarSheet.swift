import AppKit
import SwiftUI

/// Instructional sheet guiding the user to add a calendar account to the
/// macOS Calendar app. Shared between Onboarding and Settings.
///
/// Mirrors the established `AlertsHelpSheet` pattern: native `.sheet`,
/// numbered steps, Cancel + primary action footer.
public struct ConnectCalendarSheet: View {
    @Environment(\.dismiss) private var dismiss

    public init() {}

    public var body: some View {
        VStack(alignment: .leading, spacing: Tokens.spacingMD) {
            // Title
            Text("Connect a calendar")
                .font(.serifHeadline)
                .foregroundStyle(.ink)

            // Subtitle
            Text(
                "Biscotti reads your schedule from the Mac\u{2019}s Calendar app. "
                    + "Add your account there once and your calendars appear here automatically."
            )
            .foregroundStyle(.inkSecondary)

            // Numbered steps
            VStack(alignment: .leading, spacing: Tokens.spacingSM) {
                stepRow(number: 1, text: "Open the Calendar app on your Mac.")
                menuPathStep
                stepRow(
                    number: 3,
                    text: "Pick Google (or your provider) and sign in."
                )
                stepRow(
                    number: 4,
                    text: "Make sure the calendars you want are checked in Calendar\u{2019}s sidebar."
                )
            }

            // Footer
            HStack {
                Spacer()
                Button("Cancel") {
                    dismiss()
                }
                .keyboardShortcut(.cancelAction)

                Button {
                    openCalendarApp()
                    dismiss()
                } label: {
                    HStack(spacing: 4) {
                        Text("Open Calendar")
                        Image(systemName: "arrow.up.right")
                            .font(.system(size: 10, weight: .semibold))
                    }
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
                .tint(.sage)
            }
        }
        .padding(Tokens.spacingLG)
        .frame(width: 520)
    }

    // MARK: - Step rows

    private func stepRow(number: Int, text: String) -> some View {
        HStack(alignment: .top, spacing: Tokens.spacingSM) {
            Text("\(number).")
                .monospacedDigit()
            Text(text)
        }
    }

    /// Step 2 with the mono chip for the menu path.
    private var menuPathStep: some View {
        HStack(alignment: .top, spacing: Tokens.spacingSM) {
            Text("2.")
                .monospacedDigit()

            // Wrapping text + inline chip
            Text("In the menu bar, choose ")
                + Text("Calendar \u{25B8} Add Account\u{2026}")
                .font(.biscottiMono(12))
                + Text(".")
        }
    }

    // MARK: - Actions

    private func openCalendarApp() {
        if let url = NSWorkspace.shared.urlForApplication(
            withBundleIdentifier: "com.apple.iCal"
        ) {
            NSWorkspace.shared.open(url)
        }
    }
}

// MARK: - More Info Link

/// A sage "More info >" link button. Shared between the quiet hint and
/// empty-state views to open the ConnectCalendarSheet.
public struct MoreInfoLink: View {
    private let action: () -> Void

    public init(action: @escaping () -> Void) {
        self.action = action
    }

    public var body: some View {
        Button(action: action) {
            HStack(spacing: 3) {
                Text("More info")
                    .font(.system(size: 13, weight: .semibold))
                Image(systemName: "chevron.right")
                    .font(.system(size: 9, weight: .bold))
            }
            .foregroundStyle(.sage)
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Missing Calendars Hint

/// Quiet informational line shown beneath a populated calendar list.
/// Reads "Missing calendars? Connect them in the Apple Calendar app."
/// with a "More info >" link that opens the ConnectCalendarSheet.
///
/// Do **not** show alongside the empty-state view (the empty state
/// carries its own "More info" trigger).
public struct MissingCalendarsHint: View {
    private let onMoreInfo: () -> Void

    public init(onMoreInfo: @escaping () -> Void) {
        self.onMoreInfo = onMoreInfo
    }

    public var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "info.circle")
                .font(.system(size: 13))
                .foregroundStyle(.inkTertiary)

            Text("Missing calendars? Connect them in the Apple Calendar app.")
                .font(.system(size: 13))
                .foregroundStyle(.inkSecondary)

            MoreInfoLink(action: onMoreInfo)
        }
    }
}

#Preview("ConnectCalendarSheet") {
    ConnectCalendarSheet()
        .frame(height: 400)
}

#Preview("MissingCalendarsHint") {
    MissingCalendarsHint(onMoreInfo: {})
        .padding()
        .background(Tokens.contentBackground)
}
