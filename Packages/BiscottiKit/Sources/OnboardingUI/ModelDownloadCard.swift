import DesignSystem
import SwiftUI

// MARK: - ModelCard

/// Three-row card for the model download onboarding step.
/// Transcription, Speaker ID, and Language Model rows separated
/// by inset dividers matching the permission card chrome.
struct ModelCard: View {
    @Bindable var viewModel: OnboardingViewModel

    var body: some View {
        VStack(spacing: 0) {
            transcriptionRow

            InsetDivider(leadingInset: 48)

            speakerIDRow

            InsetDivider(leadingInset: 48)

            languageRow
        }
        .homeCard()
        .frame(maxWidth: 560)
    }

    private var transcriptionRow: some View {
        let state = viewModel.transcriptionRowState()
        return ModelDownloadRow(
            icon: "waveform",
            name: "Transcription",
            why: "Turns speech into text.",
            state: state,
            onDownload: {
                Task { await viewModel.startTranscriptionDownload() }
            },
            extraContent: {
                if case .downloading = state {} else {
                    RecommendationLine(
                        modelName: viewModel.transcriptionLineText,
                        onChange: { viewModel.showSpeechSheet = true }
                    )
                }
            }
        )
    }

    private var speakerIDRow: some View {
        ModelDownloadRow(
            icon: "person.2",
            name: "Speaker ID",
            why: "Labels who\u{2019}s speaking.",
            state: viewModel.speakerIDRowState(),
            onDownload: {
                Task { await viewModel.startSpeakerIDDownload() }
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
                if case .downloading = state {} else {
                    RecommendationLine(
                        modelName: viewModel.languageLineText,
                        onChange: { viewModel.showVariantSheet = true }
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
                    .fixedSize(horizontal: false, vertical: true)

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

            case let .ready(caption):
                GrantedTag("READY")
                if let caption {
                    Text(caption)
                        .font(.biscottiMono(11))
                        .foregroundStyle(.inkTertiary)
                }

            case .insufficientDisk:
                diskWarning

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

    // MARK: - Disk warning

    private var diskWarning: some View {
        HStack(spacing: 4) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.caption2)
            Text("Insufficient free space on disk")
                .font(.system(size: 12.5))
                .multilineTextAlignment(.center)
        }
        .foregroundStyle(.warningOchre)
    }
}

// MARK: - RecommendationLine

/// Model-name + "Change…" line for onboarding rows.
/// IBM Plex Mono (`.biscottiMono`) 11.5pt for the model label, SF 12.5
/// semibold for the link. Wraps: the model string never truncates; if the
/// row is too narrow "Change…" drops to a second line.
struct RecommendationLine: View {
    let modelName: String?
    let onChange: () -> Void

    var body: some View {
        FlowLayout(horizontalSpacing: 12, verticalSpacing: 4) {
            if let modelName {
                Text(modelName)
                    .font(.biscottiMono(11.5))
                    .foregroundStyle(.inkSecondary)
                    .tracking(0.115) // ~0.01em at 11.5pt
                    .lineLimit(1)
                    .fixedSize()
            }

            Button(action: onChange) {
                Text("Change\u{2026}")
                    .font(.system(size: 12.5, weight: .semibold))
            }
            .buttonStyle(ChangeLinkStyle())
        }
        .padding(.top, 7)
    }
}

// MARK: - ChangeLinkStyle

/// Inline text-link button style: `.inkSecondary` at rest, `.ink` on
/// hover or press. No background chrome.
struct ChangeLinkStyle: ButtonStyle {
    @State private var isHovered = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundStyle(
                configuration.isPressed || isHovered
                    ? Color.ink : Color.inkSecondary
            )
            .onHover { isHovered = $0 }
    }
}
