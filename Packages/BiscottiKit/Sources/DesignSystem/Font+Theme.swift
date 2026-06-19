import SwiftUI

// MARK: - Mono weight

/// Weight variants for the bundled JetBrains Mono font.
public enum MonoWeight: Sendable {
    case regular
    case medium

    /// PostScript name for this weight.
    public var postScriptName: String {
        switch self {
        case .regular: "JetBrainsMono-Regular"
        case .medium: "JetBrainsMono-Medium"
        }
    }
}

// MARK: - Font factories

public extension Font {
    /// Newsreader Display (serif), weight 500. Registration is ensured on first use.
    static func biscottiSerif(_ size: CGFloat) -> Font {
        FontRegistration.ensure()
        return .custom("NewsreaderDisplay-Medium", size: size)
    }

    /// JetBrains Mono (tabular figures by default). Registration is ensured on first use.
    static func biscottiMono(_ size: CGFloat, weight: MonoWeight = .regular) -> Font {
        FontRegistration.ensure()
        return .custom(weight.postScriptName, size: size)
    }
}

// MARK: - Semantic type ramp

public extension Font {
    /// Greeting: Newsreader Display ~32, weight 500.
    /// Apply `Tokens.greetingTracking` (-0.32) via `.tracking()`.
    static let serifGreeting: Font = .biscottiSerif(32)

    /// Onboarding headline / large empty-state headline: Newsreader Display, weight 500.
    /// Uses the `.title2` point size (~22).
    static let serifHeadline: Font = .biscottiSerif(22)

    /// Date line: JetBrains Mono 15pt regular.
    static let monoDate: Font = .biscottiMono(15)

    /// Times ("9:00 AM"), past meta ("Today . 32m"), sidebar meeting time.
    static let monoMeta: Font = .biscottiMono(12.5)

    /// Countdown ("in 6m"): JetBrains Mono 12.5pt medium.
    static let monoMetaMedium: Font = .biscottiMono(12.5, weight: .medium)

    /// Stat chip value: JetBrains Mono 12.5pt medium.
    static let monoStat: Font = .biscottiMono(12.5, weight: .medium)

    /// "+N" overflow badge: JetBrains Mono ~9pt medium.
    static let monoBadge: Font = .biscottiMono(9, weight: .medium)

    /// Kicker labels ("UPCOMING", "PAST MEETINGS"): JetBrains Mono 10.5pt medium.
    /// Combine with `.kicker()` modifier for uppercase + tracking.
    static let monoKicker: Font = .biscottiMono(10.5, weight: .medium)

    /// Recording elapsed counter: JetBrains Mono largeTitle (~34pt), weight 500.
    static let monoElapsed: Font = .biscottiMono(34, weight: .medium)

    /// Audio transport times: JetBrains Mono caption (~10pt).
    static let monoCaption: Font = .biscottiMono(10)
}
