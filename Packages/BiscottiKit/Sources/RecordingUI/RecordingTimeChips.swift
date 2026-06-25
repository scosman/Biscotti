import DesignSystem
import SwiftUI

/// Time chip views for the recording pane.
///
/// Extracted from `RecordingView` to keep the main struct under the
/// lint body-length limit.
extension RecordingView {
    /// The time chips row: Elapsed (always) + Remaining/Over (conditional).
    ///
    /// Both chips are computed from the **same** `context.date` inside a
    /// single `TimelineView`, anchored to a whole-second boundary. This
    /// guarantees ELAPSED and REMAINING/OVER flip on the exact same frame --
    /// no desync from the engine's async elapsed pump.
    var timeChipsRow: some View {
        TimelineView(
            .periodic(from: Self.wholeSecondAnchor(), by: 1)
        ) { context in
            let now = context.date
            let elapsed = RecordingViewModel.computeElapsed(
                startDate: viewModel.recordingStartDate,
                now: now
            )
            let chip = RecordingViewModel.remainingChip(
                scheduledEnd: viewModel.scheduledEnd,
                now: now
            )

            HStack(spacing: 9) {
                timeChip(
                    kicker: "ELAPSED",
                    value: elapsed,
                    style: .neutral
                )

                switch chip {
                case .none:
                    EmptyView()
                case let .normal(label):
                    timeChip(
                        kicker: "REMAINING",
                        value: label,
                        style: .neutral
                    )
                case let .warning(label):
                    timeChip(
                        kicker: "REMAINING",
                        value: label,
                        style: .warning
                    )
                case let .overtime(label):
                    timeChip(
                        kicker: "OVER",
                        value: label,
                        style: .warning
                    )
                }
            }
        }
    }

    /// Returns the start of the current clock second, so the periodic
    /// schedule is aligned to whole-second boundaries. Both chips flip
    /// when the wall-clock second changes, not offset by a random
    /// sub-second amount from when the view appeared.
    private static func wholeSecondAnchor() -> Date {
        let now = Date().timeIntervalSinceReferenceDate
        return Date(timeIntervalSinceReferenceDate: now.rounded(.down))
    }

    enum ChipStyle {
        case neutral
        case warning
    }

    func timeChip(
        kicker: String, value: String, style: ChipStyle
    ) -> some View {
        let fillColor: Color = style == .warning
            ? Tokens.warningChipFill : Color.neutralChip
        let kickerColor: Color = style == .warning
            ? Tokens.warningChipText : Color.inkTertiary
        let valueColor: Color = style == .warning
            ? Tokens.warningChipText : Color.ink

        return HStack(spacing: 6) {
            Text(kicker)
                .font(.biscottiMono(9.5, weight: .medium))
                .tracking(1.4)
                .foregroundStyle(kickerColor)
            Text(value)
                .font(.biscottiMono(14, weight: .medium))
                .foregroundStyle(valueColor)
                .monospacedDigit()

            if style == .warning {
                warningDotView
            }
        }
        .padding(.horizontal, 14)
        .frame(height: 34)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(fillColor)
        )
    }

    var warningDotView: some View {
        WarningDot(reduceMotion: reduceMotion)
    }
}

/// Pulsing 6pt warningOchre dot for warning/overtime time chips.
///
/// Owns its own `@State` for the opacity animation. Steady (no pulse)
/// when Reduce Motion is on. Uses explicit opacity animation because
/// `.symbolEffect(.pulse)` only works on SF Symbol `Image` views.
private struct WarningDot: View {
    let reduceMotion: Bool
    @State private var pulseActive = false

    var body: some View {
        Circle()
            .fill(Color.warningOchre)
            .frame(width: 6, height: 6)
            .opacity(pulseActive ? 0.25 : 1)
            .animation(
                reduceMotion
                    ? nil
                    : .easeInOut(duration: 0.8)
                    .repeatForever(autoreverses: true),
                value: pulseActive
            )
            .onAppear {
                guard !reduceMotion else { return }
                pulseActive = true
            }
    }
}
