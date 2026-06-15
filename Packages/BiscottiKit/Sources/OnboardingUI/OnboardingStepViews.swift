import Calendar
import DesignSystem
import Permissions
import SwiftUI

// MARK: - Individual step views (extracted for type_body_length)

extension OnboardingView {
    // MARK: - Welcome

    var welcomeStep: some View {
        wizardPage(
            title: "Welcome to Biscotti",
            explanation: "Private, on-device meeting transcripts. "
                + "Nothing leaves your Mac."
        ) {
            EmptyView()
        }
    }

    // MARK: - Microphone

    var microphoneStep: some View {
        wizardPage(
            title: "Microphone access",
            explanation: "Biscotti records your voice locally to "
                + "transcribe your meetings."
        ) {
            VStack(spacing: Tokens.spacingSM) {
                if !viewModel.microphoneGranted {
                    Button("Allow Microphone") {
                        Task { await viewModel.requestPermission() }
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                }

                denialGuidance(
                    state: viewModel.microphoneResult,
                    kind: .microphone
                )
            }
        }
    }

    // MARK: - System Audio

    var systemAudioStep: some View {
        wizardPage(
            title: "System audio",
            explanation: "Capture meeting audio from apps like Zoom "
                + "and Teams."
        ) {
            VStack(spacing: Tokens.spacingSM) {
                if !viewModel.systemAudioGranted {
                    Button("Allow System Audio") {
                        Task { await viewModel.requestPermission() }
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                }

                denialGuidance(
                    state: viewModel.systemAudioResult,
                    kind: .systemAudio
                )
            }
        }
    }

    // MARK: - Calendar

    var calendarStep: some View {
        wizardPage(
            title: "Calendar access",
            explanation: "See upcoming meetings and auto-link "
                + "recordings to events."
        ) {
            VStack(spacing: Tokens.spacingSM) {
                if !viewModel.calendarGranted {
                    Button("Allow Calendar Access") {
                        Task { await viewModel.requestPermission() }
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                }

                denialGuidance(
                    state: viewModel.calendarResult,
                    kind: .calendar
                )
            }
        }
    }

    // MARK: - Calendar Selection

    var calendarSelectionStep: some View {
        wizardPage(
            title: "Choose calendars",
            explanation: "Select which calendars to monitor for "
                + "meetings."
        ) {
            calendarToggles
        }
    }

    private var calendarToggles: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Tokens.spacingSM) {
                ForEach(viewModel.calendarGroups) { group in
                    Text(group.sourceTitle)
                        .font(Tokens.sectionHeaderFont)
                        .foregroundStyle(Tokens.secondaryText)

                    ForEach(group.calendars) { cal in
                        Toggle(isOn: calendarBinding(cal.id)) {
                            HStack(spacing: Tokens.spacingSM) {
                                Circle()
                                    .fill(Color(hex: cal.colorHex))
                                    .frame(width: 10, height: 10)
                                Text(cal.title)
                            }
                        }
                    }
                }
            }
            .frame(maxWidth: 400)
        }
    }

    private func calendarBinding(_ calID: String) -> Binding<Bool> {
        Binding(
            get: { viewModel.isCalendarEnabled(calID) },
            set: { _ in Task { await viewModel.toggleCalendar(calID) } }
        )
    }

    // MARK: - Notifications

    var notificationsStep: some View {
        wizardPage(
            title: "Notifications",
            explanation: "Get notified when meetings start so you "
                + "can record."
        ) {
            VStack(spacing: Tokens.spacingSM) {
                if !viewModel.notificationsGranted {
                    Button("Allow Notifications") {
                        Task { await viewModel.requestPermission() }
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                } else {
                    Label("Notifications enabled", systemImage: "checkmark.circle.fill")
                        .foregroundStyle(.sage)
                        .font(Tokens.metadataFont)
                }
            }
        }
    }

    // MARK: - Model Download

    var modelDownloadStep: some View {
        wizardPage(
            title: "Download Local AI Models",
            explanation: "A one-time download (~1.5 GB). Runs "
                + "entirely on your Mac."
        ) {
            VStack(spacing: Tokens.spacingSM) {
                if !viewModel.hasSufficientDisk {
                    Banner(
                        "Not enough disk space. Need ~"
                            + "\(OnboardingViewModel.requiredDiskSpaceMB) MB.",
                        style: .warning
                    )
                } else if viewModel.downloadComplete {
                    Label("Models ready", systemImage: "checkmark.circle.fill")
                        .foregroundStyle(.sage)
                } else if viewModel.isDownloading {
                    VStack(spacing: Tokens.spacingXS) {
                        ProgressView()
                        if let status = viewModel.downloadStatus {
                            Text(status)
                                .font(Tokens.metadataFont)
                                .foregroundStyle(Tokens.secondaryText)
                        }
                    }
                } else {
                    Button("Download Now") {
                        Task { await viewModel.startDownload() }
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                }
            }
        }
    }

    // MARK: - Launch at Login

    var launchAtLoginStep: some View {
        VStack(spacing: Tokens.spacingLG) {
            Text("Launch at Login")
                .font(.serifHeadline)

            Text(
                "Start Biscotti when you start your computer?"
            )
            .font(Tokens.metadataFont)
            .foregroundStyle(Tokens.secondaryText)
            .multilineTextAlignment(.center)
            .frame(maxWidth: 400)

            HStack(spacing: Tokens.spacingMD) {
                Button("No") {
                    Task {
                        await viewModel.setLaunchAtLogin(false)
                        await viewModel.advance()
                    }
                }
                .buttonStyle(.bordered)
                .controlSize(.large)

                Button("Yes") {
                    Task {
                        await viewModel.setLaunchAtLogin(true)
                        await viewModel.advance()
                    }
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
            }
        }
    }

    // MARK: - Done

    var doneStep: some View {
        VStack(spacing: Tokens.spacingLG) {
            Text("You\u{2019}re all set!")
                .font(.serifHeadline)

            Text("Start recording your first meeting.")
                .font(Tokens.metadataFont)
                .foregroundStyle(Tokens.secondaryText)

            Button("Get Started") {
                Task { await viewModel.completeOnboarding() }
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
        }
    }

    // MARK: - Wizard page scaffold

    func wizardPage(
        title: String,
        explanation: String,
        @ViewBuilder content: () -> some View
    ) -> some View {
        VStack(spacing: Tokens.spacingLG) {
            Text(title)
                .font(.serifHeadline)

            Text(explanation)
                .font(Tokens.metadataFont)
                .foregroundStyle(Tokens.secondaryText)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 400)

            content()

            // Single conditional footer button: Continue (prominent)
            // when the step's action is done, Skip (secondary) when not.
            if viewModel.isCurrentStepComplete {
                Button("Continue") {
                    Task { await viewModel.advance() }
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
            } else {
                Button("Skip") {
                    Task { await viewModel.skip() }
                }
                .buttonStyle(.plain)
                .foregroundStyle(Tokens.secondaryText)
            }
        }
    }

    // MARK: - Denial guidance

    @ViewBuilder
    func denialGuidance(
        state: PermissionState,
        kind: PermissionKind
    ) -> some View {
        if state == .denied {
            HStack(spacing: Tokens.spacingXS) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.warningOchre)
                Text("Denied?")
                    .font(Tokens.metadataFont)
                    .foregroundStyle(Tokens.secondaryText)
                Button("Open System Settings") {
                    viewModel.openSettings(for: kind)
                }
                .font(Tokens.metadataFont)
                .buttonStyle(.plain)
                .foregroundStyle(.sage)
            }
        } else if state == .authorized {
            Label("Granted", systemImage: "checkmark.circle.fill")
                .foregroundStyle(.sage)
                .font(Tokens.metadataFont)
        }
    }
}
