import AppCore
import AppKit
import Calendar
import DataStore
import DesignSystem
import SwiftUI
import TranscriptionService

/// The Meeting Detail screen showing metadata, transcript, calendar
/// context, and status.
///
/// Drives off three states: processing (download/transcribe in progress),
/// transcript (ready to display), and failed (with optional retry).
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

                // Calendar context block
                calendarSection
                    .padding(.bottom, Tokens.spacingMD)

                // Re-transcribe prompt after association correction
                if viewModel.showReTranscribeAfterCorrection {
                    reTranscribePrompt
                        .padding(.bottom, Tokens.spacingMD)
                }

                stateContent
            }
            .padding(Tokens.spacingLG)
        }
        .frame(
            maxWidth: .infinity,
            maxHeight: .infinity,
            alignment: .topLeading
        )
        .task { await viewModel.load() }
        .onChange(of: viewModel.currentJobStatus) { _, newStatus in
            Task { await viewModel.onJobStatusChange(newStatus) }
        }
        .sheet(isPresented: $viewModel.showEventPicker) {
            EventPickerSheet(viewModel: viewModel)
        }
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

    // MARK: - Calendar context

    @ViewBuilder
    private var calendarSection: some View {
        if let ctx = viewModel.calendarContext {
            CalendarContextBlock(
                platform: ctx.conferencePlatform,
                conferenceURL: ctx.conferenceURL,
                calendarTitle: ctx.calendarTitle,
                calendarColorHex: ctx.calendarColorHex,
                location: ctx.location,
                organizer: ctx.organizer?.name,
                attendees: ctx.attendees.map(\.name),
                isStale: ctx.isStale,
                onJoin: ctx.conferenceURL != nil
                    ? { openConferenceURL(ctx.conferenceURL) }
                    : nil,
                onChange: {
                    viewModel.presentAssociationCorrection()
                }
            )
        } else if viewModel.showLinkEventPrompt {
            Button("Link a calendar event\u{2026}") {
                viewModel.presentAssociationCorrection()
            }
            .font(.caption)
            .foregroundStyle(Tokens.secondaryText)
        }
    }

    private var reTranscribePrompt: some View {
        HStack {
            Text("Calendar event changed. Re-transcribe for updated vocabulary?")
                .font(.caption)
                .foregroundStyle(Tokens.secondaryText)

            Spacer()

            if viewModel.canReTranscribe {
                Button("Re-transcribe") {
                    viewModel.dismissReTranscribePrompt()
                    Task { await viewModel.reTranscribe() }
                }
                .buttonStyle(.bordered)
                .controlSize(.mini)
            }

            Button("Dismiss") {
                viewModel.dismissReTranscribePrompt()
            }
            .buttonStyle(.borderless)
            .controlSize(.mini)
        }
        .padding(Tokens.spacingSM)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(Color.accentColor.opacity(0.08))
        )
    }

    // MARK: - State content

    @ViewBuilder
    private var stateContent: some View {
        switch viewModel.displayState {
        case let .processing(message, subtitle):
            processingView(message: message, subtitle: subtitle)

        case let .transcript(detail):
            transcriptView(detail: detail)

        case let .failed(message, retriable):
            failedView(message: message, retriable: retriable)
        }
    }

    private func processingView(
        message: String,
        subtitle: String?
    ) -> some View {
        VStack(spacing: Tokens.spacingMD) {
            Spacer(minLength: Tokens.spacingXL)
            StatusRow(message, subtitle: subtitle)
            Spacer(minLength: Tokens.spacingXL)
        }
        .frame(maxWidth: .infinity)
    }

    @ViewBuilder
    private func transcriptView(detail: MeetingDetailData) -> some View {
        if let transcript = detail.preferredTranscript,
           !transcript.segments.isEmpty
        {
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

    private func failedView(
        message: String,
        retriable: Bool
    ) -> some View {
        VStack(spacing: Tokens.spacingMD) {
            Spacer(minLength: Tokens.spacingXL)

            Banner(
                message,
                style: .error,
                actionLabel: retriable ? "Retry" : nil,
                action: retriable
                    ? { Task { await viewModel.retry() } }
                    : nil
            )
            .frame(maxWidth: 500)

            Spacer(minLength: Tokens.spacingXL)
        }
        .frame(maxWidth: .infinity)
    }

    // MARK: - Helpers

    private func openConferenceURL(_ url: URL?) {
        guard let url else { return }
        NSWorkspace.shared.open(url)
    }
}

// MARK: - Event Picker Sheet

/// Small internal sheet for association correction: lists upcoming
/// meeting-like events and a "Remove association" option.
struct EventPickerSheet: View {
    @Bindable var viewModel: MeetingDetailViewModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: Tokens.spacingMD) {
            Text("Choose a calendar event")
                .font(.headline)

            if viewModel.availableEvents.isEmpty {
                Text("No upcoming events.")
                    .font(Tokens.metadataFont)
                    .foregroundStyle(Tokens.secondaryText)
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(viewModel.availableEvents) { event in
                            Button {
                                Task {
                                    await viewModel.correctAssociation(
                                        eventKey: event.id
                                    )
                                    dismiss()
                                }
                            } label: {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(event.title)
                                        .font(.body)
                                    HStack {
                                        Text(Self.formatEventTime(event))
                                            .font(Tokens.metadataFont)
                                            .foregroundStyle(Tokens.secondaryText)
                                        if let platform = event.conferencePlatform {
                                            Text(platform)
                                                .font(.caption2)
                                                .foregroundStyle(Tokens.secondaryText)
                                        }
                                    }
                                }
                                .padding(.vertical, Tokens.spacingXS)
                                .frame(
                                    maxWidth: .infinity,
                                    alignment: .leading
                                )
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
                .frame(maxHeight: 300)
            }

            Divider()

            HStack {
                if viewModel.hasCalendarContext {
                    Button("Remove association") {
                        Task {
                            await viewModel.removeAssociation()
                            dismiss()
                        }
                    }
                    .foregroundStyle(.red)
                }
                Spacer()
                Button("Cancel") { dismiss() }
            }
        }
        .padding(Tokens.spacingLG)
        .frame(minWidth: 350)
    }

    private static let timeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .short
        formatter.timeStyle = .short
        return formatter
    }()

    static func formatEventTime(_ event: CalendarEvent) -> String {
        timeFormatter.string(from: event.start)
    }
}

#Preview("Meeting Detail - Processing") {
    let core = try! PreviewAppCore.make() // swiftlint:disable:this force_try
    let viewModel = MeetingDetailViewModel(core: core, meetingID: UUID())
    MeetingDetailView(viewModel: viewModel)
        .frame(width: 500, height: 400)
}
