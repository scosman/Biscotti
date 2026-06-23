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
            extraContent: {
                if case .idle = state {
                    RecommendationLine(
                        modelName: viewModel.recommendedLanguageDisplayName,
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
                    .lineLimit(2)

                extraContent
            }

            Spacer(minLength: 0)

            // Trailing download control
            DownloadControl(state: state, onDownload: onDownload)
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

// MARK: - DownloadControl

/// The trailing control for a model download row.
/// Switches on `ModelRowState` to show the appropriate UI.
struct DownloadControl: View {
    let state: ModelRowState
    let onDownload: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(alignment: .trailing, spacing: 6) {
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

            case let .downloading(progress):
                downloadingContent(progress)

            case .ready:
                GrantedTag("READY")

            case .insufficientDisk:
                diskWarning

            case let .failed(message):
                Text(message)
                    .font(.biscottiMono(11))
                    .foregroundStyle(.signalRed)
                    .multilineTextAlignment(.trailing)
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
    }

    // MARK: - Downloading states

    @ViewBuilder
    private func downloadingContent(_ progress: RowDownloadProgress) -> some View {
        switch progress {
        case let .indeterminate(status):
            indeterminateBar
            if let status {
                Text(status)
                    .font(.biscottiMono(11))
                    .foregroundStyle(.inkSecondary)
                    .lineLimit(1)
            }

        case let .determinate(fraction):
            if let fraction {
                determinateBar(fraction: fraction)
                Text("Downloading\u{2026} \(Int(fraction * 100))%")
                    .font(.biscottiMono(11))
                    .foregroundStyle(.inkSecondary)
            } else {
                indeterminateBar
                Text("Downloading\u{2026}")
                    .font(.biscottiMono(11))
                    .foregroundStyle(.inkSecondary)
            }
        }
    }

    /// Indeterminate sage capsule bar (240x3, fill half-width, centered).
    private var indeterminateBar: some View {
        ZStack(alignment: .leading) {
            Capsule()
                .fill(Color.hairline)
                .frame(width: 240, height: 3)
            Capsule()
                .fill(Color.sage)
                .frame(width: 120, height: 3)
        }
    }

    /// Determinate sage capsule bar (240x3, fill proportional to fraction).
    private func determinateBar(fraction: Double) -> some View {
        ZStack(alignment: .leading) {
            Capsule()
                .fill(Color.hairline)
                .frame(width: 240, height: 3)
            Capsule()
                .fill(Color.sage)
                .frame(
                    width: max(3, 240 * min(fraction, 1.0)),
                    height: 3
                )
                .animation(
                    reduceMotion ? .none : .easeInOut(duration: 0.2),
                    value: fraction
                )
        }
    }

    // MARK: - Disk warning

    private var diskWarning: some View {
        HStack(spacing: 4) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.caption2)
            Text("Insufficient free space on disk")
                .font(.system(size: 12.5))
        }
        .foregroundStyle(.warningOchre)
    }
}

// MARK: - RecommendationLine

/// Grey line showing the recommended model and a "See all options"
/// affordance. Shown only when the language row is idle.
struct RecommendationLine: View {
    let modelName: String?
    let onSeeAll: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            if let modelName {
                Text("Recommended \u{00B7} \(modelName)")
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
