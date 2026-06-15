import AppCore
import DesignSystem
import SwiftUI

/// The active-recording screen: elapsed time, meeting title, stop button,
/// and an optional system-audio denial banner.
///
/// Big, calm, single-purpose. Centered layout with a blinking record dot
/// (opacity pulse -- the "VCR LED" option from app_overview.md).
public struct RecordingView: View {
    @Bindable private var viewModel: RecordingViewModel
    @State private var dotOpacity: Double = 1.0

    public init(viewModel: RecordingViewModel) {
        self.viewModel = viewModel
    }

    public var body: some View {
        VStack(spacing: Tokens.spacingLG) {
            Spacer()

            recordingIndicator

            elapsedTime

            if let title = viewModel.meetingTitle {
                Text(title)
                    .font(Tokens.metadataFont)
                    .foregroundStyle(Tokens.secondaryText)
            }

            stopButton

            if viewModel.showSystemAudioWarning {
                systemAudioBanner
            }

            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(Tokens.spacingXL)
    }

    // MARK: - Subviews

    private var recordingIndicator: some View {
        HStack(spacing: Tokens.spacingSM) {
            Circle()
                .fill(Tokens.recordingRed)
                .frame(width: 12, height: 12)
                .opacity(dotOpacity)
                .animation(
                    .easeInOut(duration: 1.0).repeatForever(autoreverses: true),
                    value: dotOpacity
                )
                .onAppear { dotOpacity = 0.3 }

            Text("Recording")
                .font(Tokens.meetingTitleFont)
        }
    }

    private var elapsedTime: some View {
        Text(viewModel.elapsedText)
            .font(Tokens.elapsedTimeFont)
    }

    private var stopButton: some View {
        Button {
            Task { await viewModel.stop() }
        } label: {
            Label {
                Text("Stop")
                    .fontWeight(.semibold)
            } icon: {
                Image(systemName: "stop.fill")
            }
            .padding(.horizontal, Tokens.spacingMD)
            .padding(.vertical, Tokens.spacingSM)
        }
        .buttonStyle(.borderedProminent)
        .tint(Tokens.recordingRed)
        .controlSize(.large)
    }

    private var systemAudioBanner: some View {
        Banner(
            "System audio may be denied",
            style: .warning,
            actionLabel: "Fix\u{2026}"
        ) {
            NSWorkspace.shared.open(viewModel.systemAudioSettingsURL)
        }
        .frame(maxWidth: 400)
    }
}

#Preview("Recording Screen") {
    let core = try! PreviewAppCore.make() // swiftlint:disable:this force_try
    let viewModel = RecordingViewModel(core: core)
    RecordingView(viewModel: viewModel)
        .frame(width: 500, height: 400)
}
