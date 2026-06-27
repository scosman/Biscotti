import AppKit
import Calendar
import DesignSystem
import ModelManagementUI
import Permissions
import SwiftUI

// MARK: - Per-screen views

extension OnboardingView {
    // MARK: - Welcome

    var welcomeStep: some View {
        VStack(spacing: 0) {
            Text("Welcome to Biscotti")
                .font(.biscottiSerif(46))
                .foregroundStyle(.ink)

            Text(
                "Private, on-device meeting transcripts.\nNothing you say ever leaves your Mac."
            )
            .font(.system(size: 16))
            .foregroundStyle(.inkSecondary)
            .frame(maxWidth: 460)
            .padding(.top, 16)

            Button("Continue") {
                Task { await viewModel.advance() }
            }
            .buttonStyle(OnboardingPrimaryButtonStyle())
            .padding(.top, 30)
        }
    }

    // MARK: - Grant Access (consolidated permissions)

    var grantAccessStep: some View {
        VStack(spacing: 0) {
            Text("Grant access")
                .font(.biscottiSerif(34))
                .foregroundStyle(.ink)

            Text(
                "A few quick permissions \u{2014} every one is used "
                    + "locally, nothing is sent anywhere."
            )
            .font(.system(size: 16))
            .foregroundStyle(.inkSecondary)
            .frame(maxWidth: 440)
            .padding(.top, 12)

            // Permission card
            permissionCard
                .padding(.top, 20)

            // Footer: Skip or Continue
            footerButton
                .padding(.top, 24)
        }
        .fixPermissionsAlert(
            isPresented: $viewModel.showFixPermissionsAlert,
            title: SystemAudioPermissionState.fixPermissionsAlertTitle,
            body: SystemAudioPermissionState.fixPermissionsAlertBody,
            onOpenSettings: { viewModel.openSystemAudioSettings() }
        )
    }

    // MARK: - Permission card

    private var permissionCard: some View {
        VStack(spacing: 0) {
            microphoneRow

            InsetDivider(leadingInset: 48)

            systemAudioRow

            InsetDivider(leadingInset: 48)

            calendarRow

            InsetDivider(leadingInset: 48)

            notificationsRow
        }
        .homeCard()
        .frame(maxWidth: 520)
    }

    // MARK: - Microphone row

    private var microphoneRow: some View {
        PermissionRow(
            icon: "mic.fill",
            name: "Microphone",
            why: "Record your voice locally to transcribe your meetings."
        ) {
            if viewModel.microphoneGranted {
                GrantedTag()
            } else {
                GrantPill {
                    Task { await viewModel.requestMicrophone() }
                }
            }
        } denial: {
            if viewModel.microphoneResult == .denied {
                DenialGuidanceView {
                    viewModel.openSettings(for: .microphone)
                }
            }
        }
    }

    // MARK: - System Audio row

    private var systemAudioRow: some View {
        PermissionRow(
            icon: "speaker.wave.2.fill",
            name: "System Audio",
            why: "Capture the other side of your call."
        ) {
            if viewModel.isValidatingSystemAudio {
                HStack(spacing: 4) {
                    ProgressView()
                        .controlSize(.small)
                    Text("Validating\u{2026}")
                        .font(.biscottiMono(11))
                        .foregroundStyle(.inkSecondary)
                }
            } else {
                switch viewModel.systemAudioResult {
                case .notRequested:
                    GrantPill {
                        Task { await viewModel.requestSystemAudio() }
                    }
                case .requestedNotVerified:
                    VStack(alignment: .trailing, spacing: 6) {
                        Text("Not approved")
                            .font(.biscottiMono(11))
                            .foregroundStyle(.inkSecondary)
                        HStack(spacing: 8) {
                            Button("Retry") {
                                Task { await viewModel.requestSystemAudio() }
                            }
                            .buttonStyle(JoinRecordButtonStyle())

                            Button("Fix") {
                                viewModel.showFixPermissionsAlert = true
                            }
                            .font(.system(size: 13))
                            .buttonStyle(.plain)
                            .foregroundStyle(.sage)
                        }
                    }
                case .approved:
                    GrantedTag()
                }
            }
        }
    }

    // MARK: - Calendar row

    private var calendarRow: some View {
        PermissionRow(
            icon: "calendar",
            name: "Calendar",
            why: "Join meetings and connect event data"
        ) {
            if viewModel.calendarGranted {
                GrantedTag()
            } else {
                GrantPill {
                    Task { await viewModel.requestCalendar() }
                }
            }
        } denial: {
            if viewModel.calendarResult == .denied {
                DenialGuidanceView {
                    viewModel.openSettings(for: .calendar)
                }
            }
        }
    }

    // MARK: - Notifications row

    private var notificationsRow: some View {
        PermissionRow(
            icon: "bell.fill",
            name: "Notifications",
            why: "Alerts when meetings are starting"
        ) {
            if viewModel.notificationsGranted {
                GrantedTag()
            } else {
                GrantPill {
                    Task { await viewModel.requestNotifications() }
                }
            }
        }
    }

    // MARK: - Calendar Selection

    var calendarSelectionStep: some View {
        VStack(spacing: 0) {
            Text("Choose calendars")
                .font(.biscottiSerif(34))
                .foregroundStyle(.ink)

            Text("Select which calendars to monitor for meetings.")
                .font(.system(size: 16))
                .foregroundStyle(.inkSecondary)
                .padding(.top, 12)

            if viewModel.calendarGroups.isEmpty {
                calendarEmptyState
                    .padding(.top, 20)
            } else {
                calendarToggles
                    .padding(.top, 20)

                MissingCalendarsHint(onMoreInfo: {
                    viewModel.showConnectCalendarSheet = true
                })
                .padding(.top, Tokens.spacingSM)
            }

            Button("Continue") {
                Task { await viewModel.advance() }
            }
            .buttonStyle(OnboardingPrimaryButtonStyle())
            .padding(.top, 24)
        }
        .sheet(isPresented: $viewModel.showConnectCalendarSheet) {
            ConnectCalendarSheet()
        }
        .onReceive(
            NotificationCenter.default.publisher(
                for: NSApplication.didBecomeActiveNotification
            )
        ) { _ in
            Task { await viewModel.reloadCalendars() }
        }
    }

    /// Rich empty state for onboarding: icon tile + serif headline + body + "More info".
    private var calendarEmptyState: some View {
        VStack(spacing: Tokens.spacingSM) {
            // Calendar icon tile
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

            Text(
                "If you use Google Calendar in the browser, add your Google account to the Mac\u{2019}s Calendar app so Biscotti can see your events."
            )
            .font(.system(size: 14))
            .foregroundStyle(.inkSecondary)
            .multilineTextAlignment(.center)
            .frame(maxWidth: 400)

            MoreInfoLink(action: {
                viewModel.showConnectCalendarSheet = true
            })
        }
        .padding(Tokens.spacingLG)
        .homeCard()
        .frame(maxWidth: 520)
    }

    private var calendarToggles: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                ForEach(viewModel.calendarGroups) { group in
                    Text(group.sourceTitle)
                        .kicker()
                        .foregroundStyle(.inkSecondary)

                    ForEach(group.calendars) { cal in
                        Toggle(isOn: calendarBinding(cal.id)) {
                            HStack(spacing: 8) {
                                Circle()
                                    .fill(Color(hex: cal.colorHex))
                                    .frame(width: 10, height: 10)
                                Text(cal.title)
                                    .font(.system(size: 14.5))
                            }
                        }
                        .tint(.sage)
                    }
                }
            }
            .padding(16)
        }
        .homeCard()
        .frame(maxWidth: 520, maxHeight: 280)
    }

    private func calendarBinding(_ calID: String) -> Binding<Bool> {
        Binding(
            get: { viewModel.isCalendarEnabled(calID) },
            set: { _ in Task { await viewModel.toggleCalendar(calID) } }
        )
    }

    // MARK: - Model Download

    var modelDownloadStep: some View {
        VStack(spacing: 0) {
            Text("Download Local AI Models")
                .font(.biscottiSerif(34))
                .foregroundStyle(.ink)

            Text(
                "One-time download. AI runs locally \u{2014} nothing leaves your Mac."
            )
            .font(.system(size: 16))
            .foregroundStyle(.inkSecondary)
            .frame(maxWidth: 430)
            .padding(.top, 12)

            ModelCard(viewModel: viewModel)
                .padding(.top, 20)

            footerButton
                .padding(.top, 24)
        }
        .sheet(isPresented: $viewModel.showVariantSheet) {
            ManageModelsSheet(
                viewModel: ManageModelsViewModel(core: viewModel.appCore)
            )
        }
    }

    // MARK: - Done

    var doneStep: some View {
        VStack(spacing: 0) {
            Text("You\u{2019}re all set")
                .font(.biscottiSerif(50))
                .foregroundStyle(.ink)

            Text("Start recording your first meeting whenever you like.")
                .font(.system(size: 16))
                .foregroundStyle(.inkSecondary)
                .padding(.top, 18)

            Button("Get Started") {
                Task { await viewModel.completeOnboarding() }
            }
            .buttonStyle(OnboardingPrimaryButtonStyle())
            .padding(.top, 30)
        }
    }

    // MARK: - Shared footer button

    var footerButton: some View {
        VStack(spacing: 6) {
            // Fixed min-height so toggling Skip <-> Continue doesn't
            // shift the layout vertically (the primary button is taller
            // than the plain Skip link).
            Group {
                if viewModel.isCurrentStepComplete {
                    Button("Continue") {
                        Task { await viewModel.advance() }
                    }
                    .buttonStyle(OnboardingPrimaryButtonStyle())
                } else {
                    Button("Skip") {
                        Task { await viewModel.skip() }
                    }
                    .buttonStyle(.plain)
                    .font(.system(size: 13.5))
                    .foregroundStyle(.inkTertiary)
                }
            }
            .frame(minHeight: 40)

            // Always present (blank => reserves one line, no layout shift).
            Text(viewModel.footerCaption.isEmpty ? " " : viewModel.footerCaption)
                .font(.biscottiMono(11))
                .foregroundStyle(.inkSecondary)
                .multilineTextAlignment(.center)
                .lineLimit(1)
                .padding(.top, 2)
        }
    }
}
