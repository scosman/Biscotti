import AppCore
import DesignSystem
import SwiftUI
import TranscriptionService

// MARK: - SpeechModelSheet

/// Sheet listing Apple Speech and Whisper with per-state actions.
/// Presented from Settings "Speech to Text Model" row and onboarding.
public struct SpeechModelSheet: View {
    @Bindable var viewModel: SpeechModelSheetViewModel

    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL

    public init(viewModel: SpeechModelSheetViewModel) {
        self.viewModel = viewModel
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: Tokens.spacingMD) {
            // Header
            Text("Speech to Text Model")
                .font(.headline)

            Text(
                "Choose the model used to transcribe your meetings. Both run entirely on your Mac."
            )
            .font(Tokens.metadataFont)
            .foregroundStyle(Tokens.secondaryText)

            // Engine rows
            VStack(spacing: Tokens.spacingSM) {
                ForEach(viewModel.rows) { row in
                    SpeechEngineRowView(
                        row: row,
                        localeOptions: viewModel.localeOptions,
                        selectedLocale: viewModel.selectedLocale,
                        onDownload: { viewModel.tapDownload(row.engine) },
                        onRetry: { viewModel.tapRetry(row.engine) },
                        onChoose: { viewModel.tapChoose(row.engine) },
                        onDelete: { viewModel.tapDelete() },
                        onLearnMore: { viewModel.showLearnMore = true },
                        onLocale: { viewModel.setLocale($0) }
                    )
                }
            }

            // Footer
            HStack {
                Spacer()
                Button("Done") {
                    dismiss()
                }
                .keyboardShortcut(.cancelAction)
            }
        }
        .padding(Tokens.spacingMD * 1.5)
        .frame(width: 520)
        .task { await viewModel.onAppear() }
        // Learn more alert (macOS 15)
        .alert(
            "Apple Speech requires macOS 26",
            isPresented: $viewModel.showLearnMore
        ) {
            Button("Not Now", role: .cancel) {}
            Button("Software Update\u{2026}") {
                if let url = URL(
                    string:
                    "x-apple.systempreferences:com.apple.Software-Update-Settings.extension"
                ) {
                    openURL(url)
                }
            }
        } message: {
            Text(viewModel.learnMoreMessage)
        }
        // Turn off vocabulary alert
        .alert(
            "Turn Off Custom Vocabulary?",
            isPresented: $viewModel.showTurnOffVocabulary
        ) {
            Button("Cancel", role: .cancel) {
                viewModel.cancelTurnOffVocabulary()
            }
            Button("Turn Off and Switch") {
                viewModel.confirmTurnOffVocabulary()
            }
        } message: {
            Text(
                "Apple Speech doesn\u{2019}t support custom vocabulary. You need to disable it to switch models."
            )
        }
        // Delete Whisper confirmation
        .confirmationDialog(
            "Delete Whisper?",
            isPresented: $viewModel.showDeleteWhisper,
            titleVisibility: .visible
        ) {
            Button("Delete", role: .destructive) {
                viewModel.confirmDelete()
            }
        } message: {
            Text(viewModel.deleteMessage)
        }
    }
}

// MARK: - SpeechEngineRowView

/// A single engine row in the Speech to Text Model sheet.
struct SpeechEngineRowView: View {
    let row: SpeechEngineRow
    let localeOptions: [AppleLocaleOption]
    let selectedLocale: String
    let onDownload: () -> Void
    let onRetry: () -> Void
    let onChoose: () -> Void
    let onDelete: () -> Void
    let onLearnMore: () -> Void
    let onLocale: (String) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            // Content area (dimmed when unavailable)
            VStack(alignment: .leading, spacing: 9) {
                // Recommended badge (own line)
                if row.isRecommended {
                    RecommendedBadge()
                }

                // Name line + selection control
                HStack {
                    Text(row.name)
                        .font(.system(size: 13.5, weight: .semibold))

                    Spacer()

                    selectionControl
                }

                // Trait grid
                traitGrid

                // Progress / failure
                progressContent
            }
            .opacity(row.unavailable != nil ? 0.5 : 1.0)

            // Footer: hairline + technical/unavailable line + primary action (full opacity)
            footerLine
        }
        .padding(.top, 12)
        .padding(.horizontal, 12)
        .padding(.bottom, 10)
        .background(Color.neutralChip.opacity(0.5))
        .clipShape(RoundedRectangle(cornerRadius: Tokens.buttonRadius))
    }

    // MARK: - Selection control

    @ViewBuilder
    private var selectionControl: some View {
        switch row.selection {
        case .isDefault:
            DefaultIndicator()
        case .choose:
            Button("Choose Model") {
                onChoose()
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
        case .none:
            EmptyView()
        }
    }

    // MARK: - Trait grid

    private var traitGrid: some View {
        LazyVGrid(
            columns: [
                GridItem(.flexible(), spacing: 14),
                GridItem(.flexible())
            ],
            alignment: .leading,
            spacing: 7
        ) {
            ForEach(Array(row.traits.enumerated()), id: \.offset) { _, trait in
                traitCell(trait)
            }
        }
    }

    private func traitCell(_ trait: SpeechEngineRow.Trait) -> some View {
        HStack(spacing: 6) {
            Circle()
                .fill(trait.isPro ? Color.sage.opacity(0.14) : Color.neutralChip)
                .frame(width: 15, height: 15)
                .overlay(
                    Image(systemName: trait.isPro ? "checkmark" : "minus")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(trait.isPro ? .sage : .inkTertiary)
                )

            if trait.hasLocalePicker {
                HStack(spacing: 4) {
                    Text(trait.text)
                        .font(.system(size: 12.5))
                        .foregroundStyle(trait.isPro ? .ink : .inkSecondary)
                        .fixedSize()
                        .layoutPriority(1)

                    localePicker
                }
            } else {
                Text(trait.text)
                    .font(.system(size: 12.5))
                    .foregroundStyle(trait.isPro ? .ink : .inkSecondary)
            }
        }
    }

    private var localePicker: some View {
        Picker("", selection: Binding(
            get: { selectedLocale },
            set: { onLocale($0) }
        )) {
            ForEach(localeOptions) { option in
                Text(option.displayName).tag(option.id)
            }
        }
        .pickerStyle(.menu)
        .controlSize(.small)
        .labelsHidden()
    }

    // MARK: - Progress content

    @ViewBuilder
    private var progressContent: some View {
        switch row.progress {
        case let .determinate(fraction):
            ProgressView(value: fraction)
            Text("Downloading\u{2026} \(Int(fraction * 100))%")
                .font(Tokens.metadataFont)
                .foregroundStyle(Tokens.secondaryText)

        case .indeterminate:
            HStack(spacing: 6) {
                ProgressView()
                    .controlSize(.small)
                Text("Downloading\u{2026}")
                    .font(Tokens.metadataFont)
                    .foregroundStyle(Tokens.secondaryText)
            }

        case let .failed(message):
            Text("Download failed: \(message)")
                .font(Tokens.metadataFont)
                .foregroundStyle(.signalRedText)

        case .insufficientDisk:
            WarningChip(text: "Insufficient free space on disk")

        case .none:
            EmptyView()
        }
    }

    // MARK: - Footer line

    private var footerLine: some View {
        VStack(spacing: 0) {
            Rectangle()
                .fill(Color.hairline)
                .frame(height: 0.5)
                .padding(.bottom, 8)

            if let unavailable = row.unavailable {
                HStack(spacing: 6) {
                    switch unavailable {
                    case .requiresOSUpdate:
                        WarningChip(text: "Requires macOS 26 or later")
                        Button("Learn more\u{2026}") {
                            onLearnMore()
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(.sage)
                        .font(.system(size: 12))
                    case .notAvailable:
                        WarningChip(text: "Not available on this Mac")
                    }
                    Spacer()
                }
            } else {
                HStack {
                    Text(row.technicalLine)
                        .font(.biscottiMono(10.5))
                        .foregroundStyle(.inkTertiary)
                        .tracking(0.02 * 10.5)

                    Spacer()

                    primaryAction
                }
            }
        }
    }

    // MARK: - Primary action

    @ViewBuilder
    private var primaryAction: some View {
        switch row.action {
        case let .download(enabled):
            Button("Download") {
                onDownload()
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .disabled(!enabled)

        case .retry:
            Button("Retry") {
                onRetry()
            }
            .buttonStyle(.bordered)
            .controlSize(.small)

        case let .delete(enabled):
            Button("Delete") {
                onDelete()
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .disabled(!enabled)

        case .none:
            EmptyView()
        }
    }
}
