import DesignSystem
import LiveTranscriptionService
import SwiftUI

/// The live transcript's toggle: a 44 pt circle while the drawer is
/// collapsed, the footer's leading control while it is open. It never moves;
/// the drawer grows around it.
struct LiveToggleButton: View {
    static let size: CGFloat = 44

    let viewModel: RecordingViewModel
    @State private var isHovered = false

    var body: some View {
        let isExpanded = viewModel.isDrawerExpanded
        Button {
            viewModel.toggleDrawer()
        } label: {
            HStack(spacing: Tokens.spacingXS) {
                LiveLevelIndicator(viewModel: viewModel)
                Image(systemName: isExpanded ? "chevron.down" : "chevron.up")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(.inkSecondary)
            }
        }
        .buttonStyle(LiveToggleStyle(isExpanded: isExpanded, isHovered: isHovered))
        .onHover { isHovered = $0 }
        .help(Self.tooltip(isExpanded: isExpanded, status: viewModel.liveStatus))
        .accessibilityLabel(isExpanded ? "Hide transcript" : "Show transcript")
        .accessibilityValue(viewModel.liveAccessibilityValue)
    }

    /// "Show transcript (⌘T)", after the reason when live text is unavailable.
    static func tooltip(isExpanded: Bool, status: LiveStatus) -> String {
        let action = isExpanded ? "Hide transcript (\u{2318}T)" : "Show transcript (\u{2318}T)"
        guard case let .unavailable(reason) = status else { return action }
        return "\(RecordingViewModel.unavailableText(for: reason)). \(action)"
    }
}

/// The toggle's circle: card-filled and shadowed while collapsed, bare while
/// it sits in the open drawer's footer. Hover fills it with `neutralChip`;
/// pressing darkens it by a further 6%.
private struct LiveToggleStyle: ButtonStyle {
    let isExpanded: Bool
    let isHovered: Bool

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .frame(width: LiveToggleButton.size, height: LiveToggleButton.size)
            .background {
                ZStack {
                    if !isExpanded {
                        Circle()
                            .fill(Tokens.cardFill)
                            .shadow(color: Tokens.cardShadow, radius: 6, y: 2)
                        Circle()
                            .strokeBorder(Tokens.cardStroke, lineWidth: 0.5)
                    }
                    if isHovered || configuration.isPressed {
                        Circle().fill(Tokens.neutralChip)
                    }
                    if configuration.isPressed {
                        Circle().fill(Color.ink.opacity(0.06))
                    }
                }
            }
            .contentShape(Circle())
    }
}

/// The spinner while starting, otherwise the level meter. Its own view, so
/// the level's 12 updates a second redraw only this.
private struct LiveLevelIndicator: View {
    let viewModel: RecordingViewModel

    var body: some View {
        if viewModel.liveStatus == .starting {
            ProgressView()
                .controlSize(.mini)
                .frame(width: LevelMeter.width, height: LevelMeter.maxHeight)
        } else {
            LevelMeter(level: viewModel.liveLevel, style: LevelMeter.Style(viewModel.liveStatus))
        }
    }
}

/// Four rounded bars following the combined mic and system level.
struct LevelMeter: View {
    enum Style: Equatable {
        /// Sage bars moving with the level.
        case live
        /// Still sage bars at 50% opacity.
        case paused
        /// Still `inkTertiary` bars.
        case unavailable

        init(_ status: LiveStatus) {
            switch status {
            case .paused: self = .paused
            case .unavailable, .off: self = .unavailable
            case .starting, .live, .catchingUp: self = .live
            }
        }
    }

    static let barWidth: CGFloat = 3
    static let barSpacing: CGFloat = 2
    static let minHeight: CGFloat = 6
    static let maxHeight: CGFloat = 16
    static let width = barWidth * 4 + barSpacing * 3
    /// Each bar's share of the level, so the four do not rise as one block.
    static let barWeights: [CGFloat] = [0.6, 1, 0.8, 0.45]

    let level: Float
    let style: Style
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let moving = style == .live && !reduceMotion
        let heights = Self.barHeights(level: moving ? level : nil)
        HStack(spacing: Self.barSpacing) {
            ForEach(heights.indices, id: \.self) { index in
                Capsule()
                    .fill(style == .unavailable ? Color.inkTertiary : Color.sage)
                    .frame(width: Self.barWidth, height: heights[index])
            }
        }
        .frame(width: Self.width, height: Self.maxHeight)
        .opacity(style == .paused ? 0.5 : 1)
        .animation(moving ? .linear(duration: 0.08) : nil, value: heights)
        .accessibilityHidden(true)
    }

    /// Bar heights for a level, or the still mid-height shape for nil.
    /// Speech sits around 0.5 to 0.75 of the −60…0 dBFS range; the bars use
    /// the part above 0.25 so room noise stays low.
    static func barHeights(level: Float?) -> [CGFloat] {
        let amount = level.map { min(1, max(0, (CGFloat($0) - 0.25) / 0.6)) } ?? 0.5
        return barWeights.map { weight in
            let share = level == nil ? weight * amount : max(0.08, weight * amount)
            return minHeight + (maxHeight - minHeight) * share
        }
    }
}
