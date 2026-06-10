import AppCore
import Calendar
import DataStore
import Foundation
import TranscriptionService

/// The three display states of the Meeting Detail screen.
public enum MeetingDetailState: Sendable, Equatable {
    /// Model download or transcription is in progress. `subtitle` carries
    /// the engine's live status message (e.g. download progress) when available.
    case processing(message: String, subtitle: String? = nil)

    /// A transcript is available for display.
    case transcript(MeetingDetailData)

    /// The job failed; the user may retry if `retriable` is true.
    case failed(message: String, retriable: Bool)
}

/// View model for the Meeting Detail screen.
///
/// Loads the meeting's detail data from `DataStore`, observes
/// `TranscriptionService.jobs[meetingID]` for live status, and
/// surfaces one of three states: processing, transcript, or failed.
///
/// Stage C additions: calendar context display, association correction,
/// audio playback, transcript version switching, and notes autosave.
@MainActor @Observable
public final class MeetingDetailViewModel {
    private let core: AppCore
    private let meetingID: UUID
    private let makePlayer: () -> any AudioPlaybackProviding

    /// The meeting detail data loaded from the store.
    public private(set) var detail: MeetingDetailData?

    /// The loading flag for the initial data fetch.
    public private(set) var isLoading: Bool = true

    /// Calendar context loaded from the store's snapshot.
    public private(set) var calendarContext: CalendarContextData?

    /// Whether to show the event picker sheet for association correction.
    public var showEventPicker: Bool = false

    /// Whether to show a re-transcribe prompt after association correction.
    public private(set) var showReTranscribeAfterCorrection: Bool = false

    // MARK: - Phase 8: Audio playback

    /// The audio player instance, nil if no audio file is available.
    public private(set) var audioPlayer: (any AudioPlaybackProviding)?

    /// Whether audio files are present for this meeting.
    public private(set) var isAudioAvailable: Bool = false

    /// Stored playback state, updated by a periodic ticker so SwiftUI
    /// observes changes (the underlying player is non-`@Observable`).
    public private(set) var isPlaying: Bool = false

    /// Stored playback position, updated by the ticker ~4x/s while playing.
    public private(set) var playbackCurrentTime: TimeInterval = 0

    /// Stored total duration of the loaded audio.
    public private(set) var playbackDuration: TimeInterval = 0

    /// The periodic ticker task that syncs player state into stored
    /// `@Observable` properties. Runs while playing; cancelled on
    /// pause, stop, end-of-playback, flush, or dealloc.
    private var playbackTickerTask: Task<Void, Never>?

    /// Ticker interval (250ms = ~4 updates/sec for smooth scrubbing).
    private static let tickerInterval: Duration = .milliseconds(250)

    // MARK: - Phase 8: Transcript versions

    /// All transcript versions for the meeting.
    public private(set) var versions: [TranscriptVersionData] = []

    /// The ID of the explicitly selected version, nil = use preferred.
    public var selectedVersionID: UUID?

    /// The loaded transcript for the selected (non-preferred) version.
    public private(set) var selectedTranscript: TranscriptData?

    // MARK: - Phase 8: Notes

    /// The user-editable notes, two-way bound to the text editor.
    public var notes: String = ""

    /// Debounce handle for notes autosave.
    private var notesAutosaveTask: Task<Void, Never>?

    /// Debounce interval for notes autosave.
    private static let notesDebounceInterval: Duration = .seconds(1)

    public init(
        core: AppCore,
        meetingID: UUID,
        makePlayer: @escaping () -> any AudioPlaybackProviding
            = { AVAudioPlayerWrapper() }
    ) {
        self.core = core
        self.meetingID = meetingID
        self.makePlayer = makePlayer
    }

    // MARK: - Derived state

    /// The current display state.
    public var displayState: MeetingDetailState {
        let jobStatus = core.transcription.jobs[meetingID]

        switch jobStatus {
        case let .downloadingModel(message):
            return .processing(
                message: "Transcribing\u{2026}", subtitle: message
            )

        case .transcribing:
            return .processing(message: "Transcribing\u{2026}")

        case let .failed(message, retriable):
            return .failed(message: message, retriable: retriable)

        case .completed, .idle, .none:
            if let detail, detail.preferredTranscript != nil {
                return .transcript(detail)
            }
            if isLoading {
                return .processing(message: "Loading\u{2026}")
            }
            if let detail {
                return .transcript(detail)
            }
            return .failed(message: "Meeting not found.", retriable: false)
        }
    }

    /// The current transcription job status for this meeting.
    public var currentJobStatus: JobStatus? {
        core.transcription.jobs[meetingID]
    }

    /// Whether the Re-transcribe action should be enabled.
    public var canReTranscribe: Bool {
        guard let detail, detail.hasAudio else { return false }
        let jobStatus = core.transcription.jobs[meetingID]
        switch jobStatus {
        case .downloadingModel, .transcribing:
            return false
        default:
            return true
        }
    }

    /// The meeting title for the header.
    public var title: String {
        detail?.title ?? ""
    }

    /// Formatted date for display.
    public var formattedDate: String {
        guard let detail else { return "" }
        return Self.formatDate(detail.date)
    }

    /// Formatted duration for display (e.g. "4m 12s").
    public var formattedDuration: String? {
        guard let duration = detail?.duration else { return nil }
        return Self.formatDuration(duration)
    }

    /// Whether the meeting has calendar context.
    public var hasCalendarContext: Bool {
        calendarContext != nil
    }

    /// Whether to show the quiet "Link a calendar event..." prompt.
    public var showLinkEventPrompt: Bool {
        !hasCalendarContext
    }

    /// The upcoming events available for association correction.
    public var availableEvents: [CalendarEvent] {
        core.upcoming
    }

    /// Whether audio playback is available.
    public var canPlay: Bool {
        isAudioAvailable && audioPlayer != nil
    }

    /// The active version ID: explicit selection or the preferred version.
    public var activeVersionID: UUID? {
        selectedVersionID ?? detail?.preferredTranscript?.id
    }

    /// The transcript to display: selected version or preferred.
    public var displayedTranscript: TranscriptData? {
        selectedTranscript ?? detail?.preferredTranscript
    }

    // MARK: - Actions

    /// Loads the meeting detail from the store.
    public func load() async {
        isLoading = true
        do {
            detail = try await core.store.meetingDetail(id: meetingID)
            calendarContext = detail?.calendar
            notes = detail?.notes ?? ""
            versions = detail?.versions ?? []
            await loadAudioPlayer()
        } catch {
            detail = nil
            calendarContext = nil
        }
        isLoading = false
    }

    /// Called when the transcription job status changes for this meeting.
    public func onJobStatusChange(_ newStatus: JobStatus?) async {
        if newStatus == .completed {
            do {
                detail = try await core.store.meetingDetail(id: meetingID)
                versions = detail?.versions ?? []
                selectedVersionID = nil
                selectedTranscript = nil
            } catch {
                // Non-fatal.
            }
            await core.reloadSummaries()
        }
    }

    /// Triggers a re-transcription of the meeting.
    public func reTranscribe() async {
        await core.transcription.reTranscribe(meetingID: meetingID)
        await load()
    }

    /// Retries a failed transcription.
    public func retry() async {
        await core.transcription.transcribe(meetingID: meetingID)
        await load()
    }

    /// Opens the event picker for association correction.
    public func presentAssociationCorrection() {
        showEventPicker = true
    }

    /// Corrects the association to a new event (or removes it if nil).
    public func correctAssociation(eventKey: String?) async {
        await core.correctAssociation(
            meetingID: meetingID, eventKey: eventKey
        )
        await load()
        showEventPicker = false
        if eventKey != nil {
            showReTranscribeAfterCorrection = true
        }
    }

    /// Removes the calendar association.
    public func removeAssociation() async {
        await correctAssociation(eventKey: nil)
        showReTranscribeAfterCorrection = false
    }

    /// Dismisses the re-transcribe prompt.
    public func dismissReTranscribePrompt() {
        showReTranscribeAfterCorrection = false
    }

    // MARK: - Phase 8: Audio playback actions

    /// Toggles play/pause on the audio player and starts/stops the
    /// periodic ticker that keeps the stored playback state in sync.
    public func playPause() {
        guard let player = audioPlayer else { return }
        if player.isPlaying {
            player.pause()
            stopPlaybackTicker()
            syncPlaybackState()
        } else {
            player.play()
            startPlaybackTicker()
            syncPlaybackState()
        }
    }

    /// Seeks the audio player to the specified time.
    public func seek(to time: TimeInterval) {
        audioPlayer?.currentTime = time
        syncPlaybackState()
    }

    /// Stops the playback ticker and cleans up. Called on disappear/flush.
    public func stopPlayback() {
        audioPlayer?.pause()
        stopPlaybackTicker()
        syncPlaybackState()
    }

    /// Reads the current player state into stored `@Observable` properties.
    private func syncPlaybackState() {
        isPlaying = audioPlayer?.isPlaying ?? false
        playbackCurrentTime = audioPlayer?.currentTime ?? 0
        playbackDuration = audioPlayer?.duration ?? 0
    }

    /// Starts the periodic ticker that polls the player ~4x/sec.
    private func startPlaybackTicker() {
        stopPlaybackTicker()
        playbackTickerTask = Task { [weak self] in
            while !Task.isCancelled {
                do {
                    try await Task.sleep(for: Self.tickerInterval)
                } catch {
                    break
                }
                guard let self, !Task.isCancelled else { break }
                syncPlaybackState()
                // Stop the ticker if the player reached the end
                if !(audioPlayer?.isPlaying ?? false) {
                    break
                }
            }
        }
    }

    /// Cancels the periodic ticker.
    private func stopPlaybackTicker() {
        playbackTickerTask?.cancel()
        playbackTickerTask = nil
    }

    // MARK: - Phase 8: Transcript version actions

    /// Selects and loads a specific transcript version.
    public func selectVersion(_ versionID: UUID) async {
        selectedVersionID = versionID

        // If selecting the preferred version, clear the override
        if versionID == detail?.preferredTranscript?.id {
            selectedTranscript = nil
            return
        }

        do {
            selectedTranscript = try await core.store.transcript(
                id: versionID
            )
        } catch {
            selectedTranscript = nil
        }
    }

    // MARK: - Phase 8: Notes autosave

    /// Updates notes and debounces autosave to the store.
    ///
    /// Uses `[weak self]` for the short debounce window. If the VM
    /// deallocs mid-debounce, `flushNotes()` (called in `onDisappear`)
    /// is the guarantee that pending edits are persisted before teardown.
    public func updateNotes(_ text: String) {
        notes = text
        notesAutosaveTask?.cancel()
        notesAutosaveTask = Task { [weak self] in
            do {
                try await Task.sleep(for: Self.notesDebounceInterval)
            } catch {
                return // cancelled
            }
            guard let self, !Task.isCancelled else { return }
            await saveNotes()
        }
    }

    /// Flushes any pending notes autosave immediately and stops playback.
    /// Called on navigation away (onDisappear) to prevent leaked timers.
    public func flushNotes() async {
        notesAutosaveTask?.cancel()
        notesAutosaveTask = nil
        stopPlayback()
        await saveNotes()
    }

    // MARK: - Phase 8: Re-transcribe after correction

    /// Dismisses the re-transcribe prompt and triggers re-transcription.
    public func reTranscribeAfterCorrection() async {
        showReTranscribeAfterCorrection = false
        await reTranscribe()
    }
}

// MARK: - Private helpers

private extension MeetingDetailViewModel {
    func loadAudioPlayer() async {
        do {
            let refs = try await core.store.audioFileRefs(
                meetingID: meetingID
            )
            isAudioAvailable = refs.present

            guard refs.present, let micURL = refs.mic else {
                audioPlayer = nil
                syncPlaybackState()
                return
            }

            let player = makePlayer()
            try player.load(url: micURL)
            audioPlayer = player
            syncPlaybackState()
        } catch {
            audioPlayer = nil
            isAudioAvailable = false
            syncPlaybackState()
        }
    }

    func saveNotes() async {
        do {
            try await core.store.setNotes(notes, for: meetingID)
        } catch {
            // Non-fatal; notes will be retried on next edit.
        }
    }
}

// MARK: - Formatting

extension MeetingDetailViewModel {
    private static let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter
    }()

    static func formatDate(_ date: Date) -> String {
        dateFormatter.string(from: date)
    }

    static func formatDuration(_ duration: TimeInterval) -> String {
        let totalSeconds = Int(duration)
        let hours = totalSeconds / 3600
        let minutes = (totalSeconds % 3600) / 60
        let seconds = totalSeconds % 60

        if hours > 0 {
            return "\(hours)h \(minutes)m \(seconds)s"
        }
        if minutes > 0 {
            return "\(minutes)m \(seconds)s"
        }
        return "\(seconds)s"
    }
}
