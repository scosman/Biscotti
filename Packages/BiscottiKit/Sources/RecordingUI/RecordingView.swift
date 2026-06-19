import AppCore
import DesignSystem
import Recording
import SwiftUI

/// The active-recording screen: a calm, centered, document-style surface
/// with RECORDING badge, Stop & Save, editable title, submeta, time chips,
/// note composer, notes list, and system-audio banner.
public struct RecordingView: View {
    @Bindable var viewModel: RecordingViewModel
    @Environment(\.accessibilityReduceMotion) var reduceMotion

    /// Pending composer text, shared with `RecordingNotesView` so
    /// Stop & Save can commit it.
    @State private var pendingComposerText: String = ""

    /// Inline note edit state, shared with `RecordingNotesView` so
    /// Stop & Save can commit any in-progress edit before stopping.
    @State private var editingNoteID: UUID?
    @State private var editingNoteText: String = ""

    /// Ripple animation state
    @State private var rippleActive: Bool = false

    public init(viewModel: RecordingViewModel) {
        self.viewModel = viewModel
    }

    public var body: some View {
        Group {
            switch viewModel.recordingStartup {
            case .loading:
                startupLoadingView

            case let .failed(message):
                startupFailedView(message: message)

            case .started, nil:
                recordingContent
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .sheet(isPresented: $viewModel.showEventPicker) {
            EventPickerSheet(
                events: viewModel.nearbyEventPickerItems,
                hasCalendarAccess: viewModel.hasCalendarAccess,
                hasExistingAssociation: viewModel.hasEvent,
                onSelect: { eventKey in
                    Task {
                        await viewModel.correctAssociation(
                            eventKey: eventKey
                        )
                    }
                },
                onRemove: {
                    Task {
                        await viewModel.removeAssociation()
                    }
                },
                onCancel: {
                    viewModel.showEventPicker = false
                }
            )
        }
    }

    // MARK: - Startup states

    private var startupLoadingView: some View {
        VStack(spacing: Tokens.spacingMD) {
            ProgressView()
                .controlSize(.large)
            Text("Starting recording\u{2026}")
                .font(.body)
                .foregroundStyle(Color.inkSecondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func startupFailedView(message: String) -> some View {
        VStack(spacing: Tokens.spacingMD) {
            Image(systemName: "exclamationmark.triangle")
                .font(.system(size: 36))
                .foregroundStyle(Color.signalRed)

            Text("Could not start recording")
                .font(.serifHeadline)
                .foregroundStyle(Color.ink)

            Text(message)
                .font(.body)
                .foregroundStyle(Color.inkSecondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 340)

            HStack(spacing: Tokens.spacingSM) {
                Button("Cancel") {
                    viewModel.cancelStartRecording()
                }
                .buttonStyle(.plain)
                .foregroundStyle(Color.inkSecondary)

                Button {
                    Task { await viewModel.retryStartRecording() }
                } label: {
                    Text("Retry")
                        .fontWeight(.semibold)
                }
                .buttonStyle(.plain)
                .foregroundStyle(Color.sage)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var recordingContent: some View {
        GeometryReader { geometry in
            ScrollView {
                VStack(spacing: 0) {
                    Spacer(minLength: 0)

                    mainColumn

                    Spacer(minLength: 0)
                }
                .frame(
                    maxWidth: .infinity,
                    minHeight: geometry.size.height,
                    alignment: .center
                )
            }
        }
        .task(id: viewModel.meetingID) {
            await viewModel.load()
        }
        .onChange(of: viewModel.summariesVersion) {
            Task { await viewModel.reloadDetail() }
        }
    }

    // MARK: - Main column

    private var mainColumn: some View {
        VStack(alignment: .leading, spacing: Tokens.spacingLG) {
            if let autoStop = viewModel.autoStopCountdown {
                AutoStopCountdownCard(
                    state: autoStop,
                    onKeepRecording: { viewModel.keepRecording() }
                )
            }

            statusRow

            titleSection

            timeChipsRow

            Divider()
                .padding(.vertical, Tokens.spacingMD)

            RecordingNotesView(
                viewModel: viewModel,
                pendingComposerText: $pendingComposerText,
                editingNoteID: $editingNoteID,
                editingNoteText: $editingNoteText
            )

            if viewModel.showSystemAudioWarning {
                systemAudioBanner
            }
        }
        .padding(.vertical, 40)
        .padding(.horizontal, Tokens.spacingXL)
        .frame(maxWidth: 600)
    }

    // MARK: - Status row

    private var statusRow: some View {
        HStack {
            recordingBadge
            Spacer()
            stopButton
        }
    }

    private var recordingBadge: some View {
        HStack(spacing: 8) {
            ZStack {
                // Ripple rings (reduced motion: hidden)
                if !reduceMotion {
                    ForEach(0 ..< 2, id: \.self) { index in
                        Circle()
                            .stroke(Color.signalRed, lineWidth: 1)
                            .frame(width: 11, height: 11)
                            .scaleEffect(rippleActive ? 2.6 : 0.6)
                            .opacity(rippleActive ? 0 : 0.4)
                            .animation(
                                .easeOut(duration: 2.0)
                                    .repeatForever(autoreverses: false)
                                    .delay(Double(index) * 1.0),
                                value: rippleActive
                            )
                    }
                }

                // Solid dot
                Circle()
                    .fill(Color.signalRed)
                    .frame(width: 11, height: 11)
            }
            .onAppear { rippleActive = true }

            Text("RECORDING")
                .font(.biscottiMono(12.5, weight: .medium))
                .tracking(1.5)
                .foregroundStyle(Color.signalRed)
        }
    }

    private var stopButton: some View {
        Button {
            Task {
                // Commit any in-progress inline note edit
                commitPendingNoteEdit()
                await viewModel.stop(
                    pendingComposer: pendingComposerText
                )
            }
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "stop.fill")
                    .font(.system(size: 9))
                Text("Stop & Save")
                    .font(.system(size: 13, weight: .medium))
            }
            .padding(.horizontal, 15)
            .frame(height: 34)
        }
        .buttonStyle(LightAlertButtonStyle())
    }

    /// Commits any in-progress inline note edit so Stop & Save
    /// does not discard the user's unsaved changes.
    private func commitPendingNoteEdit() {
        guard let noteID = editingNoteID else { return }
        let trimmed = editingNoteText
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            viewModel.removeNote(id: noteID)
        } else {
            viewModel.updateNote(id: noteID, text: trimmed)
        }
        editingNoteID = nil
        editingNoteText = ""
    }

    // MARK: - Title + submeta

    private var titleSection: some View {
        VStack(alignment: .leading, spacing: Tokens.spacingSM) {
            EditableMeetingTitle(
                text: $viewModel.editableTitle,
                placeholder: "Untitled recording",
                font: .biscottiSerif(26)
            ) {
                await viewModel.saveTitle()
            }

            submetaLine
        }
    }

    @ViewBuilder
    private var submetaLine: some View {
        if viewModel.hasEvent {
            eventSubmeta
        } else {
            adHocSubmeta
        }
    }
}

// MARK: - Submeta sub-views

private extension RecordingView {
    /// Note: the dot separator before "Open in calendar" renders
    /// unconditionally. In practice both scheduleText and platformText
    /// are always present for event-linked meetings, so the orphan-dot
    /// edge case does not arise. Accepted per CR review.
    var eventSubmeta: some View {
        HStack(spacing: 0) {
            if let schedule = viewModel.scheduleText {
                Text(schedule)
                    .font(.monoMeta)
                    .foregroundStyle(Color.inkSecondary)
            }

            if let platform = viewModel.platformText {
                Text(" \u{00B7} ")
                    .font(.monoMeta)
                    .foregroundStyle(Color.inkTertiary)
                Text(platform)
                    .font(.monoMeta)
                    .foregroundStyle(Color.inkSecondary)
            }

            Text(" \u{00B7} ")
                .font(.monoMeta)
                .foregroundStyle(Color.inkTertiary)

            Button {
                viewModel.openInCalendar()
            } label: {
                HStack(spacing: 3) {
                    Text("Open in calendar")
                        .font(.body)
                    Image(systemName: "arrow.up.right")
                        .font(.system(size: 9, weight: .medium))
                }
                .foregroundStyle(Color.sage)
            }
            .buttonStyle(.plain)

            Text(" \u{00B7} ")
                .font(.monoMeta)
                .foregroundStyle(Color.inkTertiary)

            Button {
                Task { await viewModel.removeAssociation() }
            } label: {
                HStack(spacing: 3) {
                    Text("Unlink event")
                        .font(.body)
                    Image(systemName: "calendar.badge.minus")
                        .font(.system(size: 9, weight: .medium))
                }
                .foregroundStyle(Color.sage)
            }
            .buttonStyle(.plain)
        }
    }

    var adHocSubmeta: some View {
        HStack(spacing: 0) {
            if let clockText = viewModel.startedClockText {
                Text(clockText)
                    .font(.monoMeta)
                    .foregroundStyle(Color.inkSecondary)
            }

            Text(" \u{00B7} ")
                .font(.monoMeta)
                .foregroundStyle(Color.inkTertiary)

            Button {
                Task { await viewModel.presentLinkEvent() }
            } label: {
                HStack(spacing: 3) {
                    Text("Link event")
                        .font(.body)
                    Image(systemName: "calendar.badge.plus")
                        .font(.system(size: 9, weight: .medium))
                }
                .foregroundStyle(Color.sage)
            }
            .buttonStyle(.plain)
        }
    }

    var systemAudioBanner: some View {
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

#if DEBUG
    #Preview("Recording Screen") {
        let core = try! PreviewAppCore.make() // swiftlint:disable:this force_try
        let viewModel = RecordingViewModel(core: core)
        RecordingView(viewModel: viewModel)
            .frame(width: 600, height: 700)
            .background(Tokens.contentBackground)
    }
#endif
