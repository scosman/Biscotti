import DesignSystem
import SwiftUI

// MARK: - ModelCard

/// Two-row card for the model download onboarding step.
/// Transcription row on top, language row on bottom, separated
/// by an inset divider matching the permission card chrome.
struct ModelCard: View {
    @Bindable var viewModel: OnboardingViewModel

    var body: some View {
        VStack(spacing: 0) {
            transcriptionRow

            InsetDivider(leadingInset: 48)

            languageRow
        }
        .homeCard()
        .frame(maxWidth: 560)
    }

    private var transcriptionRow: some View {
        ModelDownloadRow(
            icon: "waveform",
            name: "Transcription & Speaker ID",
            why: "Turns speech into text and labels who\u{2019}s speaking.",
            state: viewModel.transcriptionRowState(),
            onDownload: {
                Task { await viewModel.startTranscriptionDownload() }
            }
        )
    }

    private var languageRow: some View {
        let state = viewModel.languageRowState()
        return ModelDownloadRow(
            icon: "sparkles",
            name: "Language Model",
            why: "Meeting summaries, speaker matching, and automatic titles.",
            state: state,
            onDownload: {
                viewModel.startLanguageDownload()
            },
            onCancel: {
                viewModel.cancelLanguageDownload()
            },
            extraContent: {
                if case .idle = state {
                    RecommendationLine(
                        modelName: viewModel.languageTargetDisplayName,
                        isRecommended: viewModel.languageTargetIsRecommended,
                        onSeeAll: { viewModel.showVariantSheet = true }
                    )
                }
            }
        )
    }
}

// MARK: - ModelDownloadRow

/// A single row in the model download card. Mirrors the
/// `PermissionRow` skeleton (icon tile + name + why + trailing control)
/// but top-aligned and with an optional extra content line.
struct ModelDownloadRow<ExtraContent: View>: View {
    let icon: String
    let name: String
    let why: String
    let state: ModelRowState
    let onDownload: () -> Void
    var onCancel: (() -> Void)?
    @ViewBuilder let extraContent: ExtraContent

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            // Icon tile (same metrics as PermissionRow)
            RoundedRectangle(cornerRadius: 9)
                .fill(Color.accentWashSoft)
                .frame(width: 34, height: 34)
                .overlay(
                    Image(systemName: icon)
                        .font(.system(size: 18, weight: .medium))
                        .foregroundStyle(.sage)
                )

            // Name + why + optional extra
            VStack(alignment: .leading, spacing: 2) {
                Text(name)
                    .font(.system(size: 14.5, weight: .semibold))
                    .foregroundStyle(.ink)

                Text(why)
                    .font(.system(size: 12.5))
                    .foregroundStyle(.inkSecondary)
                    .multilineTextAlignment(.leading)
                    .fixedSize(horizontal: false, vertical: true)

                extraContent
            }

            Spacer(minLength: 0)

            // Trailing download control
            DownloadControl(state: state, onDownload: onDownload, onCancel: onCancel)
        }
        .padding(.vertical, 15)
        .padding(.horizontal, 16)
    }
}

// MARK: - Convenience init (no extra content)

extension ModelDownloadRow where ExtraContent == EmptyView {
    init(
        icon: String,
        name: String,
        why: String,
        state: ModelRowState,
        onDownload: @escaping () -> Void
    ) {
        self.init(
            icon: icon,
            name: name,
            why: why,
            state: state,
            onDownload: onDownload,
            extraContent: { EmptyView() }
        )
    }
}

// MARK: - IndeterminateBar

/// A sage capsule segment that bounces back and forth within a hairline track.
/// Falls back to a static left-parked segment when Reduce Motion is on.
private struct IndeterminateBar: View {
    let trackWidth: CGFloat

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var animate = false

    private let segmentWidth: CGFloat = 40

    private var maxOffset: CGFloat {
        trackWidth - segmentWidth
    }

    var body: some View {
        ZStack(alignment: .leading) {
            Capsule()
                .fill(Color.hairline)
                .frame(width: trackWidth, height: 3)
            Capsule()
                .fill(Color.accentTrack)
                .frame(width: segmentWidth, height: 3)
                .offset(x: animate ? maxOffset : 0)
        }
        .onAppear {
            guard !reduceMotion else { return }
            withAnimation(
                .easeInOut(duration: 0.9)
                    .repeatForever(autoreverses: true)
            ) {
                animate = true
            }
        }
    }
}

// MARK: - DownloadControl

/// The trailing control for a model download row.
/// Switches on `ModelRowState` to show the appropriate UI.
struct DownloadControl: View {
    let state: ModelRowState
    let onDownload: () -> Void
    var onCancel: (() -> Void)?

    /// Shared width for the bar tracks and the entire control column.
    private let controlWidth: CGFloat = 120

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(alignment: .center, spacing: 6) {
            switch state {
            case let .idle(sizeCaption):
                GrantPill(
                    title: "Download",
                    systemImage: "arrow.down.circle",
                    action: onDownload
                )
                Text(sizeCaption)
                    .font(.biscottiMono(11))
                    .foregroundStyle(.inkTertiary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)

            case let .downloading(progress):
                downloadingContent(progress)

            case .ready:
                GrantedTag("READY")

            case let .failed(message):
                Text(message)
                    .font(.biscottiMono(11))
                    .foregroundStyle(.signalRedText)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                GrantPill(
                    title: "Retry",
                    systemImage: "arrow.clockwise",
                    action: onDownload
                )

            case .checking:
                ProgressView()
                    .controlSize(.small)
            }
        }
        .frame(width: controlWidth, alignment: .center)
    }

    // MARK: - Downloading states

    @ViewBuilder
    private func downloadingContent(_ progress: RowDownloadProgress) -> some View {
        switch progress {
        case let .indeterminate(status):
            IndeterminateBar(trackWidth: controlWidth)
            if let status {
                Text(status)
                    .font(.biscottiMono(11))
                    .foregroundStyle(.inkSecondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }

        case let .determinate(fraction):
            if let fraction {
                determinateBar(fraction: fraction)
                Text("Downloading\u{2026} \(Int(fraction * 100))%")
                    .font(.biscottiMono(11))
                    .foregroundStyle(.inkSecondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                IndeterminateBar(trackWidth: controlWidth)
                Text("Downloading\u{2026}")
                    .font(.biscottiMono(11))
                    .foregroundStyle(.inkSecondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        if let onCancel {
            Button("Cancel") {
                onCancel()
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
        }
    }

    /// Determinate sage capsule bar; fill proportional to fraction.
    private func determinateBar(fraction: Double) -> some View {
        ZStack(alignment: .leading) {
            Capsule()
                .fill(Color.hairline)
                .frame(width: controlWidth, height: 3)
            Capsule()
                .fill(Color.accentTrack)
                .frame(
                    width: max(3, controlWidth * min(fraction, 1.0)),
                    height: 3
                )
                .animation(
                    reduceMotion ? .none : .easeInOut(duration: 0.2),
                    value: fraction
                )
        }
    }
}

// MARK: - RecommendationLine

/// Grey line showing the target model name and a "See all options"
/// affordance. Shown only when the language row is idle.
/// When `isRecommended` is true, prefixes the name with "Recommended ·".
struct RecommendationLine: View {
    let modelName: String?
    let isRecommended: Bool
    let onSeeAll: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            if let modelName {
                Text(isRecommended ? "Recommended \u{00B7} \(modelName)" : modelName)
                    .font(.system(size: 12.5))
                    .foregroundStyle(.inkSecondary)
            }

            Button(action: onSeeAll) {
                HStack(spacing: 3) {
                    Text("See all options")
                        .font(.system(size: 12.5, weight: .semibold))
                    Image(systemName: "chevron.right")
                        .font(.system(size: 11))
                }
                .foregroundStyle(.inkSecondary)
            }
            .buttonStyle(.plain)
        }
        .padding(.top, 6)
    }
}
