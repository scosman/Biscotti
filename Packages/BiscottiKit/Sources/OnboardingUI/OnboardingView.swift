import AppCore
import Calendar
import DesignSystem
import Permissions
import SwiftUI

/// Full-window onboarding wizard. Steps through permissions, calendar
/// selection, and model download via the OnboardingScaffold layout.
public struct OnboardingView: View {
    @Bindable var viewModel: OnboardingViewModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    public init(viewModel: OnboardingViewModel) {
        self.viewModel = viewModel
    }

    public var body: some View {
        OnboardingScaffold(
            step: viewModel.currentStep,
            contentMaxWidth: viewModel.currentStep == .modelDownload ? 560 : 520
        ) {
            stepContent
        }
    }

    // MARK: - Step content

    private var stepContent: some View {
        Group {
            switch viewModel.currentStep {
            case .welcome:
                welcomeStep
            case .permissions:
                grantAccessStep
            case .calendarSelection:
                calendarSelectionStep
            case .modelDownload:
                modelDownloadStep
            case .done:
                doneStep
            }
        }
        .transition(
            reduceMotion
                ? .opacity
                : .opacity.combined(with: .offset(y: 8))
        )
        .animation(
            reduceMotion
                ? .none
                : .easeInOut(duration: 0.28),
            value: viewModel.currentStep
        )
    }
}

#if DEBUG
    #Preview("Onboarding") {
        let core = try! PreviewAppCore.make() // swiftlint:disable:this force_try
        let viewModel = OnboardingViewModel(core: core)
        OnboardingView(viewModel: viewModel)
            .frame(width: 800, height: 600)
    }
#endif
