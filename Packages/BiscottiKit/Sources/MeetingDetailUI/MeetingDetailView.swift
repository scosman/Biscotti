import AppCore
import DataStore
import DesignSystem
import SwiftUI
import TranscriptionService

/// The Meeting Detail screen showing metadata, transcript, and status.
///
/// Drives off three states: processing (download/transcribe in progress),
/// transcript (ready to display), and failed (with optional retry).
/// Note: version picker is deferred to Project 7. Audio playback is
/// deferred to Project 7.
public struct MeetingDetailView: View {
    @Bindable private var viewModel: MeetingDetailViewModel

    public init(viewModel: MeetingDetailViewModel) {
        self.viewModel = viewModel
    }

    public var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                header
                    .padding(.bottom, Tokens.spacingMD)

                Divider()
                    .padding(.bottom, Tokens.spacingMD)

                stateContent
            }
            .padding(Tokens.spacingLG)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .task { await viewModel.load() }
    }

    // MARK: - Header

    private var header: some View {
        VStack(alignment: .leading, spacing: Tokens.spacingXS) {
            HStack {
                Text(viewModel.title)
                    .font(Tokens.meetingTitleFont)

                Spacer()

                if viewModel.canReTranscribe {
                    Button("Re-transcribe") {
                        Task { await viewModel.reTranscribe() }
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                }
            }

            HStack(spacing: Tokens.spacingSM) {
                Text(viewModel.formattedDate)
                    .font(Tokens.metadataFont)
                    .foregroundStyle(Tokens.secondaryText)

                if let duration = viewModel.formattedDuration {
                    Text("\u{00B7}")
                        .foregroundStyle(Tokens.secondaryText)
                    Text(duration)
                        .font(Tokens.metadataFont)
                        .foregroundStyle(Tokens.secondaryText)
                }
            }
        }
    }

    // MARK: - State content

    @ViewBuilder
    private var stateContent: some View {
        switch viewModel.displayState {
        case let .processing(message):
            processingView(message: message)

        case let .transcript(detail):
            transcriptView(detail: detail)

        case let .failed(message, retriable):
            failedView(message: message, retriable: retriable)
        }
    }

    private func processingView(message: String) -> some View {
        VStack(spacing: Tokens.spacingMD) {
            Spacer(minLength: Tokens.spacingXL)
            StatusRow(message)
            Spacer(minLength: Tokens.spacingXL)
        }
        .frame(maxWidth: .infinity)
    }

    @ViewBuilder
    private func transcriptView(detail: MeetingDetailData) -> some View {
        if let transcript = detail.preferredTranscript, !transcript.segments.isEmpty {
            LazyVStack(alignment: .leading, spacing: 0) {
                ForEach(transcript.segments) { segment in
                    TranscriptSegmentRow(
                        speakerLabel: segment.speakerLabel,
                        text: segment.text
                    )
                }
            }
        } else {
            Text("No transcript available.")
                .font(Tokens.metadataFont)
                .foregroundStyle(Tokens.secondaryText)
                .padding(.vertical, Tokens.spacingLG)
        }
    }

    private func failedView(message: String, retriable: Bool) -> some View {
        VStack(spacing: Tokens.spacingMD) {
            Spacer(minLength: Tokens.spacingXL)

            Banner(
                message,
                style: .error,
                actionLabel: retriable ? "Retry" : nil,
                action: retriable ? { Task { await viewModel.retry() } } : nil
            )
            .frame(maxWidth: 500)

            Spacer(minLength: Tokens.spacingXL)
        }
        .frame(maxWidth: .infinity)
    }
}

#Preview("Meeting Detail - Processing") {
    let core = try! PreviewAppCore.make() // swiftlint:disable:this force_try
    let viewModel = MeetingDetailViewModel(core: core, meetingID: UUID())
    MeetingDetailView(viewModel: viewModel)
        .frame(width: 500, height: 400)
}
