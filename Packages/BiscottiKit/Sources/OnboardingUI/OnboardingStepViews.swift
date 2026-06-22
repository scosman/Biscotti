import Calendar
import DesignSystem
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

            calendarToggles
                .padding(.top, 20)

            Button("Continue") {
                Task { await viewModel.advance() }
            }
            .buttonStyle(OnboardingPrimaryButtonStyle())
            .padding(.top, 24)
        }
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

            (
                Text("A one-time download (")
                    .font(.system(size: 16))
                    +
                    Text("~1.5 GB")
                    .font(.biscottiMono(15))
                    +
                    Text(
                        ").\nEverything runs entirely on your Mac \u{2014} no cloud, ever."
                    )
                    .font(.system(size: 16))
            )
            .foregroundStyle(.inkSecondary)
            .frame(maxWidth: 430)
            .padding(.top, 12)

            downloadContent
                .padding(.top, 24)

            footerButton
                .padding(.top, 24)
        }
    }

    @ViewBuilder
    private var downloadContent: some View {
        if !viewModel.hasSufficientDisk {
            Banner(
                "Not enough disk space. Need ~"
                    + "\(OnboardingViewModel.requiredDiskSpaceMB) MB.",
                style: .warning
            )
            .frame(maxWidth: 520)
        } else if viewModel.downloadComplete {
            GrantedTag("COMPLETE")
        } else if viewModel.isDownloading {
            VStack(spacing: 8) {
                // Static indeterminate bar -- the download stream
                // provides status text but no numeric fraction.
                ZStack(alignment: .leading) {
                    Capsule()
                        .fill(Color.hairline)
                        .frame(width: 240, height: 3)
                    Capsule()
                        .fill(Color.sage)
                        .frame(width: 120, height: 3)
                }

                if let status = viewModel.downloadStatus {
                    Text(status)
                        .font(.biscottiMono(11))
                        .foregroundStyle(.inkSecondary)
                }
            }
        } else {
            Button {
                Task { await viewModel.startDownload() }
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "arrow.down.circle")
                        .font(.system(size: 15, weight: .medium))
                    Text("Download Now")
                }
            }
            .buttonStyle(OnboardingPrimaryButtonStyle())
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
    }
}
