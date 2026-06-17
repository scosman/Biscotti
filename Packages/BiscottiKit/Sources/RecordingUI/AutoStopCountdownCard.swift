import AppCore
import DesignSystem
import SwiftUI

/// A prominent card shown at the top of the recording pane while an
/// auto-stop countdown is active. Shows a heading, seconds remaining,
/// a decreasing progress bar, and a "Keep Recording" button.
///
/// Driven by `AutoStopState.deadline` via a `TimelineView` so no
/// per-second AppCore state is needed. Reduce Motion switches from
/// a smooth animation schedule to a periodic 1-second step.
struct AutoStopCountdownCard: View {
    let state: AutoStopState
    let onKeepRecording: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        if reduceMotion {
            TimelineView(
                .periodic(from: .now, by: 1)
            ) { context in
                cardContent(now: context.date)
            }
        } else {
            TimelineView(.animation) { context in
                cardContent(now: context.date)
            }
        }
    }

    @ViewBuilder
    private func cardContent(now: Date) -> some View {
        let remaining = max(0, state.deadline.timeIntervalSince(now))
        let fraction = state.total > 0 ? remaining / state.total : 0
        let secondsLabel = Int(ceil(remaining))

        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Auto-stopping soon")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(Color.ink)
                Spacer()
                Text("\(secondsLabel)s")
                    .font(.biscottiMono(14, weight: .medium))
                    .foregroundStyle(Color.signalRed)
                    .monospacedDigit()
            }

            countdownBar(fraction: fraction)
            keepRecordingRow
        }
        .padding(Tokens.spacingMD)
        .background(cardBackground)
        .overlay(cardBorder)
    }

    /// Right-aligned neutral "Keep Recording" button.
    private var keepRecordingRow: some View {
        HStack {
            Spacer()
            Button {
                onKeepRecording()
            } label: {
                Text("Keep Recording")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Color.ink)
            }
            .buttonStyle(.plain)
            .padding(.horizontal, 14)
            .padding(.vertical, 6)
            .background(
                RoundedRectangle(cornerRadius: Tokens.buttonRadius)
                    .fill(Color.neutralChip)
            )
            .overlay(
                RoundedRectangle(cornerRadius: Tokens.buttonRadius)
                    .strokeBorder(Color.hairline, lineWidth: 0.5)
            )
        }
    }

    /// Card fill: white card + recordingTintSoft wash.
    private var cardBackground: some View {
        RoundedRectangle(cornerRadius: Tokens.cardRadius)
            .fill(Tokens.cardFill)
            .overlay(
                RoundedRectangle(cornerRadius: Tokens.cardRadius)
                    .fill(Color.recordingTintSoft)
            )
    }

    /// Card border: cardStroke hairline + recordingOutline accent.
    private var cardBorder: some View {
        ZStack {
            RoundedRectangle(cornerRadius: Tokens.cardRadius)
                .strokeBorder(Color.cardStroke, lineWidth: 0.5)
            RoundedRectangle(cornerRadius: Tokens.cardRadius)
                .strokeBorder(Color.recordingOutline, lineWidth: 0.5)
        }
    }

    private func countdownBar(fraction: Double) -> some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule()
                    .fill(Color.neutralChip)
                Capsule()
                    .fill(Color.signalRed)
                    .frame(width: max(0, geo.size.width * fraction))
                    .animation(
                        reduceMotion ? nil : .linear(duration: 1),
                        value: fraction
                    )
            }
        }
        .frame(height: 8)
    }
}
