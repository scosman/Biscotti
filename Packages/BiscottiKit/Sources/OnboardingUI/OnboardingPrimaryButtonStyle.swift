import DesignSystem
import SwiftUI

/// Roomy sage-fill button for onboarding CTAs (Continue, Get Started,
/// Download Now). Same visual idiom as `JoinRecordButtonStyle` at
/// onboarding scale.
struct OnboardingPrimaryButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 14.5, weight: .semibold))
            .foregroundStyle(.white)
            .padding(.horizontal, 20)
            .frame(height: 40)
            .background(
                RoundedRectangle(cornerRadius: 9)
                    .fill(Color.accentFill)
                    .overlay(alignment: .top) {
                        RoundedRectangle(cornerRadius: 9)
                            .fill(
                                LinearGradient(
                                    colors: [.white.opacity(0.15), .clear],
                                    startPoint: .top,
                                    endPoint: .center
                                )
                            )
                    }
            )
            .clipShape(RoundedRectangle(cornerRadius: 9))
            .opacity(
                !isEnabled ? 0.4 : configuration.isPressed ? 0.7 : 1.0
            )
    }
}
