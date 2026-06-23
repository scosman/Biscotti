import DesignSystem
import SwiftUI

/// Three-region vertical layout for every onboarding screen:
/// ProgressHeader (top), centered content, BrandFooter (bottom).
struct OnboardingScaffold<Content: View>: View {
    let step: OnboardingViewModel.Step
    var contentMaxWidth: CGFloat = 520
    @ViewBuilder let content: Content

    var body: some View {
        VStack(spacing: 0) {
            ProgressHeader(step: step)
                .padding(.top, 28)

            Spacer(minLength: 24)

            content
                .frame(maxWidth: contentMaxWidth)
                .multilineTextAlignment(.center)

            Spacer(minLength: 24)

            BrandFooter()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(.horizontal, 40)
        .padding(.bottom, 28)
        .background(Color.paper.ignoresSafeArea())
    }
}
