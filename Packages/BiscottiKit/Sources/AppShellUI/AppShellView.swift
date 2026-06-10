import AppCore
import DesignSystem
import MeetingDetailUI
import MeetingListUI
import RecordingUI
import SwiftUI

/// The main app window: a `NavigationSplitView` with a sidebar (Record +
/// recording indicator + past meetings) and a detail pane routed by
/// `AppCore.route`.
public struct AppShellView: View {
    @Bindable private var viewModel: AppShellViewModel

    public init(viewModel: AppShellViewModel) {
        self.viewModel = viewModel
    }

    public var body: some View {
        NavigationSplitView {
            sidebar
        } detail: {
            detailContent
        }
        .task { await viewModel.onLaunch() }
    }

    // MARK: - Sidebar

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 0) {
            recordSection
                .padding(.horizontal, Tokens.spacingSM)

            if viewModel.showRecordingIndicator {
                recordingIndicator
                    .padding(.horizontal, Tokens.spacingSM)
            }

            Divider()
                .padding(.vertical, Tokens.spacingSM)

            Text("PAST")
                .font(Tokens.sectionHeaderFont)
                .foregroundStyle(Tokens.secondaryText)
                .padding(.horizontal, Tokens.spacingMD)
                .padding(.bottom, Tokens.spacingXS)

            ScrollView {
                MeetingListView(
                    viewModel: viewModel.meetingListViewModel
                )
            }
        }
        .frame(minWidth: 180, idealWidth: 220)
    }

    private var recordSection: some View {
        RecordButton(isDisabled: viewModel.recordButtonDisabled) {
            Task { await viewModel.startRecording() }
        }
    }

    private var recordingIndicator: some View {
        Button {
            viewModel.showRecording()
        } label: {
            HStack(spacing: Tokens.spacingSM) {
                Circle()
                    .fill(Tokens.recordingRed)
                    .frame(width: 8, height: 8)

                Text("Recording\u{2026}")
                    .font(.callout)

                Spacer()

                Text(viewModel.recordingElapsedText)
                    .font(.callout.monospacedDigit())
                    .foregroundStyle(Tokens.secondaryText)
            }
            .padding(.vertical, Tokens.spacingXS)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    // MARK: - Detail pane

    @ViewBuilder
    private var detailContent: some View {
        switch viewModel.route {
        case .empty:
            emptyPlaceholder

        case .recording:
            RecordingView(
                viewModel: viewModel.recordingViewModel
            )

        case let .meeting(meetingID):
            MeetingDetailView(
                viewModel: viewModel.meetingDetailViewModel(for: meetingID)
            )
            .id(meetingID)
        }
    }

    private var emptyPlaceholder: some View {
        VStack(spacing: Tokens.spacingSM) {
            Image(systemName: "waveform")
                .font(.largeTitle)
                .foregroundStyle(Tokens.secondaryText)
            Text("Select a meeting, or tap Record")
                .font(Tokens.metadataFont)
                .foregroundStyle(Tokens.secondaryText)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

#Preview("App Shell") {
    let core = try! PreviewAppCore.make() // swiftlint:disable:this force_try
    let viewModel = AppShellViewModel(core: core)
    AppShellView(viewModel: viewModel)
        .frame(width: 700, height: 500)
}
