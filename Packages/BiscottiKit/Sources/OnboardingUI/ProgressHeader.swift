import DesignSystem
import SwiftUI

/// A thin sage progress bar with a mono kicker label, centered.
/// Replaces the dot indicator from the old onboarding.
struct ProgressHeader: View {
    let step: OnboardingViewModel.Step

    /// Kicker text for each screen.
    private var kickerText: String {
        switch step {
        case .welcome: "WELCOME"
        case .permissions: "PERMISSIONS"
        case .calendarSelection: "CALENDARS"
        case .modelDownload: "AI MODELS"
        case .done: "FINISH"
        }
    }

    /// Fill fraction: (rawValue + 1) / 5.
    private var fillFraction: CGFloat {
        CGFloat(step.rawValue + 1) / CGFloat(OnboardingViewModel.Step.allCases.count)
    }

    private let trackWidth: CGFloat = 240
    private let trackHeight: CGFloat = 3

    var body: some View {
        VStack(spacing: 9) {
            ZStack(alignment: .leading) {
                Capsule()
                    .fill(Color.hairline)
                    .frame(width: trackWidth, height: trackHeight)

                Capsule()
                    .fill(Color.sage)
                    .frame(
                        width: trackWidth * fillFraction,
                        height: trackHeight
                    )
                    .animation(.easeInOut(duration: 0.25), value: step)
            }

            Text(kickerText)
                .kicker()
                .foregroundStyle(.inkSecondary)
        }
        .frame(maxWidth: .infinity)
    }
}
