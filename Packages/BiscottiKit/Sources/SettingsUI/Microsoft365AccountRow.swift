import DesignSystem
import Foundation
import GraphAuth
import SwiftUI

/// The "Microsoft 365" row at the top of Settings → Calendars: connect,
/// the connected account and its last sync, reconnect after the sign-in
/// expires, and disconnect. A standalone view (not a `SettingsView` extension) so its
/// alert state stays local.
struct Microsoft365AccountRow: View {
    let viewModel: SettingsViewModel

    @State private var confirmDisconnect = false

    static let title = "Microsoft 365"
    static let signedOutCaption = "Show meetings from your Microsoft 365 calendars."
    static let signingInCaption = "Finish signing in in the browser window."
    static let disconnectTitle = "Disconnect Microsoft 365?"

    static func reconnectCaption(_ account: Microsoft365Account) -> String {
        "The sign-in for \(account.username) has expired. Reconnect to keep reading its calendars."
    }

    /// "Synced just now" within a minute, then "Synced 5 minutes ago".
    static func syncedCaption(_ lastSynced: Date, now: Date) -> String {
        guard now.timeIntervalSince(lastSynced) >= 60 else { return "Synced just now" }
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .full
        return "Synced \(formatter.localizedString(for: lastSynced, relativeTo: now))"
    }

    static func disconnectMessage(_ account: Microsoft365Account?) -> String {
        let who = account.map { " for \($0.username)" } ?? ""
        return "Biscotti will stop reading Microsoft 365 calendars\(who). You can connect again at any time."
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Tokens.spacingXS) {
            HStack(alignment: .firstTextBaseline, spacing: Tokens.spacingSM) {
                Text(Self.title)
                Spacer()
                actions
            }
            caption
            if let error = viewModel.microsoft365Error {
                Text(error)
                    .font(Tokens.metadataFont)
                    .foregroundStyle(Tokens.signalRedText)
                    .textSelection(.enabled)
            }
        }
        .alert(Self.disconnectTitle, isPresented: $confirmDisconnect) {
            Button("Cancel", role: .cancel) {}
            Button("Disconnect", role: .destructive) {
                Task { await viewModel.disconnectMicrosoft365() }
            }
        } message: {
            Text(Self.disconnectMessage(viewModel.microsoft365State.account))
        }
    }

    @ViewBuilder
    private var actions: some View {
        switch viewModel.microsoft365State {
        case .notConfigured:
            Text("Not configured")
                .font(Tokens.metadataFont)
                .foregroundStyle(Tokens.secondaryText)
        case .signedOut:
            connectButton("Connect\u{2026}")
        case .signingIn:
            ProgressView()
                .controlSize(.small)
            Button("Cancel") { viewModel.cancelMicrosoft365SignIn() }
                .buttonStyle(.bordered)
                .controlSize(.small)
        case .signedIn:
            disconnectButton
        case .needsReconnect:
            connectButton("Reconnect\u{2026}")
            disconnectButton
        }
    }

    @ViewBuilder
    private var caption: some View {
        switch viewModel.microsoft365State {
        case let .notConfigured(reason):
            secondary(reason.userMessage)
        case .signedOut:
            secondary(Self.signedOutCaption)
        case .signingIn:
            secondary(Self.signingInCaption)
        case let .signedIn(account):
            secondary(account.displayName.map { "\($0) (\(account.username))" } ?? account.username)
            if let lastSynced = viewModel.microsoft365LastSynced {
                TimelineView(.periodic(from: .now, by: 30)) { context in
                    secondary(Self.syncedCaption(lastSynced, now: context.date))
                }
            }
        case let .needsReconnect(account):
            Label(Self.reconnectCaption(account), systemImage: "exclamationmark.triangle.fill")
                .font(Tokens.metadataFont)
                .foregroundStyle(Tokens.warningChipText)
        }
    }

    private func secondary(_ text: String) -> some View {
        Text(text)
            .font(Tokens.metadataFont)
            .foregroundStyle(Tokens.secondaryText)
    }

    private func connectButton(_ title: String) -> some View {
        Button(title) {
            Task { await viewModel.connectMicrosoft365() }
        }
        .buttonStyle(.bordered)
        .controlSize(.small)
    }

    private var disconnectButton: some View {
        Button("Disconnect\u{2026}") { confirmDisconnect = true }
            .buttonStyle(.bordered)
            .controlSize(.small)
    }
}
