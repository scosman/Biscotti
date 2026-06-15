import AppCore
import Calendar
import DataStore
import DesignSystem
import SwiftUI
import TranscriptionService

/// The Meeting Detail screen showing metadata, transcript, calendar
/// context, audio playback, notes, and status.
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

                // TODO(re-transcribe-prompt): restore the "calendar changed
                // -- re-transcribe" prompt once vocab support (Phase 9) lands.
                // The showReTranscribeAfterCorrection flag is always false until then.
                if viewModel.showReTranscribeAfterCorrection {
                    reTranscribePrompt
                        .padding(.bottom, Tokens.spacingMD)
                }

                // Audio transport — total duration uses the meeting's stored
                // recordingDuration when available; falls back to
                // AVAudioPlayer.duration (decode-time self-correction) for
                // legacy recordings without a stored duration.
                AudioTransport(
                    isPlaying: viewModel.isPlaying,
                    currentTime: viewModel.playbackCurrentTime,
                    duration: viewModel.playbackDuration,
                    isDisabled: !viewModel.canPlay,
                    onPlayPause: { viewModel.playPause() },
                    onSeek: { viewModel.seek(to: $0) }
                )
                .padding(.bottom, Tokens.spacingMD)

                Divider()
                    .padding(.bottom, Tokens.spacingMD)

                // Notes section
                notesSection
                    .padding(.bottom, Tokens.spacingMD)

                Divider()
                    .padding(.bottom, Tokens.spacingMD)

                deleteSection
                    .padding(.bottom, Tokens.spacingMD)

                Divider()
                    .padding(.bottom, Tokens.spacingMD)

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
        .onDisappear {
            Task { await viewModel.flushNotes() }
        }
        .sheet(isPresented: $viewModel.showEventPicker) {
            EventPickerSheet(viewModel: viewModel)
        }
        .confirmationDialog(
            "Delete this meeting?",
            isPresented: $viewModel.showDeleteConfirmation,
            titleVisibility: .visible
        ) {
            Button("Delete", role: .destructive) {
                Task { await viewModel.confirmDelete() }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(
                "This permanently deletes the recording and transcript."
            )
        }
    }

    // MARK: - Header

    private var header: some View {
        VStack(alignment: .leading, spacing: Tokens.spacingXS) {
            HStack {
                TextField(
                    "Meeting title",
                    text: $viewModel.editableTitle
                )
                .font(Tokens.meetingTitleFont)
                .textFieldStyle(.plain)
                .onSubmit {
                    Task { await viewModel.saveTitle() }
                }

                Spacer()

                if viewModel.versions.count > 1 {
                    versionPicker
                }

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

    // MARK: - Version picker

    private var versionPicker: some View {
        VersionPicker(
            versions: viewModel.versions.map { version in
                VersionPickerItem(
                    id: version.id,
                    dateText: Self.versionDateFormatter.string(
                        from: version.createdAt
                    ),
                    methodLabel: version.methodId,
                    isPreferred: version.isPreferred
                )
            },
            // Safe: the picker is only shown when versions.count > 1,
            // which guarantees activeVersionID is non-nil (a preferred
            // or selected version always exists when versions are loaded).
            selectedID: viewModel.activeVersionID ?? UUID(),
            onSelect: { id in
                Task { await viewModel.selectVersion(id) }
            }
        )
    }

    private static let versionDateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter
    }()

    // MARK: - Calendar context

    @ViewBuilder
    private var calendarSection: some View {
        if let ctx = viewModel.calendarContext {
            VStack(alignment: .leading, spacing: Tokens.spacingSM) {
                CalendarContextBlock(
                    platform: ctx.conferencePlatform,
                    conferenceURL: ctx.conferenceURL,
                    calendarTitle: ctx.calendarTitle,
                    calendarColorHex: ctx.calendarColorHex,
                    location: ctx.location,
                    organizer: ctx.organizer?.name,
                    attendees: ctx.attendees.map(\.name),
                    onJoin: nil,
                    onChange: {
                        Task {
                            await viewModel
                                .presentAssociationCorrection()
                        }
                    }
                )

                if viewModel.showOpenInCalendar {
                    Button {
                        viewModel.openInCalendar()
                    } label: {
                        Label(
                            "Open in Calendar",
                            systemImage: "calendar"
                        )
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                }
            }
        } else if viewModel.showLinkEventPrompt {
            Button("Link a calendar event\u{2026}") {
                Task {
                    await viewModel.presentAssociationCorrection()
                }
            }
            .font(.caption)
            .foregroundStyle(Tokens.secondaryText)
        }
    }

    private var reTranscribePrompt: some View {
        HStack {
            Text(
                "Calendar event changed. Re-transcribe for updated vocabulary?"
            )
            .font(.caption)
            .foregroundStyle(Tokens.secondaryText)

            Spacer()

            if viewModel.canReTranscribe {
                Button("Re-transcribe") {
                    Task {
                        await viewModel.reTranscribeAfterCorrection()
                    }
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

    // MARK: - Delete

    private var deleteSection: some View {
        HStack {
            Spacer()
            Button(role: .destructive) {
                viewModel.requestDelete()
            } label: {
                Label("Delete Meeting", systemImage: "trash")
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .disabled(viewModel.isDeleting)
        }
    }

    // MARK: - Notes

    private var notesSection: some View {
        VStack(alignment: .leading, spacing: Tokens.spacingXS) {
            Text("Notes")
                .font(Tokens.sectionHeaderFont)
                .foregroundStyle(Tokens.secondaryText)

            TextEditor(
                text: Binding(
                    get: { viewModel.notes },
                    set: { viewModel.updateNotes($0) }
                )
            )
            .font(.body)
            .frame(minHeight: 60)
            .scrollContentBackground(.hidden)
        }
    }
}

// MARK: - State content

private extension MeetingDetailView {
    @ViewBuilder
    var stateContent: some View {
        switch viewModel.displayState {
        case let .processing(message, subtitle):
            processingView(message: message, subtitle: subtitle)

        case .transcript:
            transcriptView

        case let .failed(message, retriable):
            failedView(message: message, retriable: retriable)
        }
    }

    func processingView(
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
    var transcriptView: some View {
        if let transcript = viewModel.displayedTranscript,
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

    func failedView(
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
                if viewModel.hasCalendarAccess {
                    Text(
                        "No calendar events near this recording\u{2019}s time."
                    )
                    .font(Tokens.metadataFont)
                    .foregroundStyle(Tokens.secondaryText)
                } else {
                    Text(
                        "Calendar access is required to link events. Grant access in System Settings \u{2192} Privacy & Security \u{2192} Calendars."
                    )
                    .font(Tokens.metadataFont)
                    .foregroundStyle(Tokens.secondaryText)
                }
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
                                            .foregroundStyle(
                                                Tokens.secondaryText
                                            )
                                        if let platform =
                                            event.conferencePlatform
                                        {
                                            Text(platform)
                                                .font(.caption2)
                                                .foregroundStyle(
                                                    Tokens.secondaryText
                                                )
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
                    .foregroundStyle(.signalRed)
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
