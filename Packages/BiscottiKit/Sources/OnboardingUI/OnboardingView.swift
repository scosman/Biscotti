import AppCore
import Calendar
import DesignSystem
import Permissions
import SwiftUI

/// Full-window onboarding wizard. Steps through permissions, calendar
/// selection, and model download, each skippable.
public struct OnboardingView: View {
    @Bindable var viewModel: OnboardingViewModel

    public init(viewModel: OnboardingViewModel) {
        self.viewModel = viewModel
    }

    public var body: some View {
        VStack(spacing: 0) {
            // Step indicator dots pinned near the top
            stepIndicator
                .padding(.top, Tokens.spacingLG)
                .padding(.bottom, Tokens.spacingMD)

            // Step content fills remaining space, centered vertically
            stepContent
                .frame(
                    maxWidth: .infinity,
                    maxHeight: .infinity
                )
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(Tokens.spacingXL)
    }

    // MARK: - Step indicator

    private var stepIndicator: some View {
        HStack(spacing: 6) {
            ForEach(0 ..< viewModel.totalSteps, id: \.self) { index in
                Circle()
                    .fill(
                        index <= viewModel.progressIndex
                            ? Color.primary
                            : Color.secondary.opacity(0.3)
                    )
                    .frame(width: 8, height: 8)
            }
        }
    }

    // MARK: - Step content

    @ViewBuilder
    private var stepContent: some View {
        switch viewModel.currentStep {
        case .welcome:
            welcomeStep
        case .microphone:
            microphoneStep
        case .systemAudio:
            systemAudioStep
        case .calendar:
            calendarStep
        case .calendarSelection:
            calendarSelectionStep
        case .notifications:
            notificationsStep
        case .modelDownload:
            modelDownloadStep
        case .launchAtLogin:
            launchAtLoginStep
        case .done:
            doneStep
        }
    }
}

#Preview("Onboarding") {
    let core = try! PreviewAppCore.make() // swiftlint:disable:this force_try
    let viewModel = OnboardingViewModel(core: core)
    OnboardingView(viewModel: viewModel)
        .frame(width: 600, height: 500)
}
