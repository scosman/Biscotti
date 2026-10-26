import DesignSystem
import GraphAuth
import SwiftUI

// MARK: - Microsoft 365 (Synderys fork, o365_calendar)

extension OnboardingView {
    static let microsoft365RowName = "Microsoft 365"
    static let microsoft365RowWhy = "Join meetings and connect event data from your work calendar"

    /// Takes the Calendar permission row's place when Microsoft 365 is the
    /// calendar source: connecting the account is the grant.
    var microsoft365Row: some View {
        PermissionRow(
            icon: "calendar",
            name: Self.microsoft365RowName,
            why: Self.microsoft365RowWhy
        ) {
            switch viewModel.microsoft365State {
            case .signedIn:
                GrantedTag("CONNECTED")
            case .signingIn:
                HStack(spacing: 8) {
                    ProgressView()
                        .controlSize(.small)
                    Button("Cancel") {
                        viewModel.cancelMicrosoft365SignIn()
                    }
                    .font(.system(size: 13))
                    .buttonStyle(.plain)
                    .foregroundStyle(.sage)
                }
            case .needsReconnect:
                GrantPill(title: "Reconnect") {
                    Task { await viewModel.connectMicrosoft365() }
                }
            case .signedOut, .notConfigured:
                GrantPill(title: "Connect") {
                    Task { await viewModel.connectMicrosoft365() }
                }
            }
        } denial: {
            if let error = viewModel.microsoft365Error {
                HStack(alignment: .firstTextBaseline, spacing: 4) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.warningOchre)
                        .font(.system(size: 12))
                    Text(error)
                        .font(.system(size: 12.5))
                        .foregroundStyle(.inkSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    /// The calendar step's empty state for a Microsoft 365 account. Unlike
    /// Apple Calendar's, it doesn't point at the Mac's Calendar app.
    var microsoft365CalendarEmptyState: some View {
        VStack(spacing: Tokens.spacingSM) {
            RoundedRectangle(cornerRadius: Tokens.buttonRadius)
                .fill(Color.neutralChip)
                .frame(width: 48, height: 48)
                .overlay(
                    Image(systemName: "calendar")
                        .font(.system(size: 22))
                        .foregroundStyle(.inkSecondary)
                )

            Text("No calendars found")
                .font(.serifHeadline)
                .foregroundStyle(.ink)

            Text(viewModel.microsoft365EmptyCalendarsMessage)
                .font(.system(size: 14))
                .foregroundStyle(.inkSecondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 400)
        }
        .padding(Tokens.spacingLG)
        .homeCard()
        .frame(maxWidth: 520)
    }
}
