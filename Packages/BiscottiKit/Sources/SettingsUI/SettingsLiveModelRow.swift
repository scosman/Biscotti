import DesignSystem
import LiveTranscriptionService
import SwiftUI

extension SettingsView {
    /// Shown under the live transcript toggle while its model is not on this
    /// Mac: offers the download, then shows its progress or its failure.
    var liveModelRow: some View {
        HStack(spacing: Tokens.spacingSM) {
            VStack(alignment: .leading, spacing: Tokens.spacingXS) {
                Text("Live Transcript Model")
                Text(Self.liveModelCaption(for: viewModel.liveModelState))
                    .font(Tokens.metadataFont)
                    .foregroundStyle(Tokens.secondaryText)
            }
            Spacer()
            switch viewModel.liveModelState {
            case .downloading:
                ProgressView()
                    .controlSize(.small)
            case .failed:
                liveModelDownloadButton("Try Again")
            case .missing, .ready:
                liveModelDownloadButton("Download")
            }
        }
    }

    /// Shown while the startup disk is low: macOS may remove the compiled
    /// speech models, so transcription can start slowly.
    var lowDiskRow: some View {
        HStack(alignment: .firstTextBaseline, spacing: Tokens.spacingSM) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.warningOchre)
                .accessibilityHidden(true)
            Text(SettingsViewModel.lowDiskWarning)
                .font(Tokens.metadataFont)
                .foregroundStyle(Tokens.secondaryText)
                .fixedSize(horizontal: false, vertical: true)
        }
        .accessibilityElement(children: .combine)
    }

    static func liveModelCaption(for state: LiveModelState) -> String {
        switch state {
        case .missing, .ready:
            "Needed for the live transcript (\(LiveTranscriptionDefaults.whisperModelMegabytes) MB)."
        case let .downloading(stage):
            stage
        case let .failed(message):
            "The download did not finish: \(message)"
        }
    }

    private func liveModelDownloadButton(_ title: String) -> some View {
        Button(title) {
            Task { await viewModel.downloadLiveModel() }
        }
        .buttonStyle(.bordered)
        .controlSize(.small)
    }
}
