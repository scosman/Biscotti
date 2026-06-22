import AppCore
import AppKit
import Calendar
import DataStore
import DesignSystem
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
/// audio playback, transcript version switching, notes autosave,
/// editable title, and Open-in-Calendar deep link.
@MainActor @Observable
public final class MeetingDetailViewModel {
    private let core: AppCore
    public let meetingID: UUID
    private let makePlayer: () -> any AudioPlaybackProviding

    /// Injectable "now" for deterministic testing of time-gated UI.
    private let currentDate: () -> Date

    /// Injectable callback for opening URLs (mirrors EventPreviewViewModel).
    /// Set by the app target to `NSWorkspace.shared.open`; tests inject a spy.
    private let urlOpener: (URL) -> Void

    /// The meeting detail data loaded from the store.
    public private(set) var detail: MeetingDetailData?

    /// The loading flag for the initial data fetch.
    public private(set) var isLoading: Bool = true

    /// Calendar context loaded from the store's snapshot.
    public private(set) var calendarContext: CalendarContextData?

    /// Whether to show the event picker sheet for association correction.
    public var showEventPicker: Bool = false

    // TODO(re-transcribe-prompt): restore the "calendar changed -- re-transcribe"
    // prompt once vocab support (Phase 9) lands. The underlying flag and plumbing
    // remain; only the UI is suppressed.

    /// Whether to show a re-transcribe prompt after association correction.
    /// Currently always false -- suppressed until vocabulary support lands.
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

    /// Current playback speed multiplier. Default 1.0.
    public private(set) var playbackRate: Float = 1.0

    /// Available speed options for the transport speed menu.
    public static let speedOptions: [Float] = [0.5, 1.0, 1.25, 1.5, 2.0]

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

    // MARK: - Association picker

    /// Calendar events near this meeting's recording time, fetched on
    /// demand when the picker opens. Replaces the forward-only
    /// `core.upcoming` so past meetings can find their real events.
    public private(set) var nearbyEvents: [CalendarEvent] = []

    /// Whether nearby events are currently being fetched.
    public private(set) var isLoadingNearbyEvents: Bool = false

    // MARK: - Phase 11: Editable title

    /// The user-editable title, two-way bound to the inline TextField.
    public var editableTitle: String = ""

    // MARK: - Tab state (lifted from view for deep-link jump)

    /// The body tabs of the meeting detail screen.
    public enum Tab: String, CaseIterable, Sendable {
        case transcript = "Transcript"
        case notes = "Notes"
    }

    /// The currently selected tab, bindable from the view.
    public var selectedTab: Tab = .transcript

    /// A pending seek time set by a deep-link jump that arrived before
    /// the audio player was loaded. Applied at the end of `loadAudioPlayer`.
    private var pendingSeek: TimeInterval?

    // MARK: - Phase 11: Delete meeting

    /// Whether the delete confirmation dialog is presented.
    public var showDeleteConfirmation: Bool = false

    /// Whether a delete operation is in progress.
    public private(set) var isDeleting: Bool = false

    public init(
        core: AppCore,
        meetingID: UUID,
        makePlayer: @escaping () -> any AudioPlaybackProviding
            = { AVAudioPlayerWrapper() },
        currentDate: @escaping () -> Date = { Date() },
        urlOpener: @escaping (URL) -> Void = { _ in }
    ) {
        self.core = core
        self.meetingID = meetingID
        self.makePlayer = makePlayer
        self.currentDate = currentDate
        self.urlOpener = urlOpener
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

    /// Calendar events available for association correction. Populated
    /// by `loadNearbyEvents()` when the picker opens, using a +/- 1.5h
    /// window around the meeting's recording time instead of the
    /// forward-only `core.upcoming`.
    public var availableEvents: [CalendarEvent] {
        nearbyEvents
    }

    /// Available events mapped to `EventPickerItem` for the shared picker
    /// sheet. Keeps the `Calendar` → `DesignSystem` mapping in the VM so
    /// the view does not need `import Calendar`.
    public var availableEventPickerItems: [EventPickerItem] {
        availableEvents.map { event in
            EventPickerItem(
                id: event.id,
                title: event.title,
                start: event.start,
                conferencePlatform: event.conferencePlatform
            )
        }
    }

    /// Whether calendar access has been granted. Used to decide between
    /// "no events near this time" vs "grant calendar access" in the picker.
    public var hasCalendarAccess: Bool {
        core.calendar.auth == .authorized
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
            editableTitle = detail?.title ?? ""
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

    /// Sets the playback speed. Applies immediately if playing.
    public func setPlaybackRate(_ rate: Float) {
        playbackRate = rate
        audioPlayer?.rate = rate
    }

    /// Seeks the audio player to the specified time.
    public func seek(to time: TimeInterval) {
        audioPlayer?.currentTime = time
        syncPlaybackState()
    }

    /// Seeks to the specified time and starts playback if paused.
    ///
    /// Used by transcript timestamp links and deep-link jumps so the
    /// user hears audio immediately after clicking a link. The
    /// transport-bar scrubber uses plain `seek(to:)` instead.
    public func seekAndPlay(to time: TimeInterval) {
        seek(to: time)
        guard let player = audioPlayer, !player.isPlaying else { return }
        player.play()
        startPlaybackTicker()
        syncPlaybackState()
    }

    /// Copies the displayed transcript to the system pasteboard as plain text.
    public func copyTranscript() {
        guard let transcript = displayedTranscript,
              !transcript.segments.isEmpty
        else { return }

        let text = TranscriptContent.plainText(transcript.segments)
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
    }

    /// Copies the current notes to the system pasteboard as plain text.
    public func copyNotes() {
        guard !notes.isEmpty else { return }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(notes, forType: .string)
    }

    /// Stops the playback ticker and cleans up. Called on disappear/flush.
    public func stopPlayback() {
        audioPlayer?.pause()
        stopPlaybackTicker()
        syncPlaybackState()
    }

    /// Reads the current player state into stored `@Observable` properties.
    ///
    /// Uses the meeting's stored `recordingDuration` as the authoritative
    /// total when available — ADTS AAC files have no container-level
    /// duration, so `AVAudioPlayer.duration` is a size/bitrate guess that
    /// is often very wrong. The player-derived value is the fallback for
    /// legacy recordings that pre-date the stored field.
    private func syncPlaybackState() {
        isPlaying = audioPlayer?.isPlaying ?? false
        playbackCurrentTime = audioPlayer?.currentTime ?? 0
        if let recDur = detail?.recordingDuration, recDur > 0 {
            playbackDuration = recDur
        } else {
            playbackDuration = audioPlayer?.duration ?? 0
        }
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
}

// MARK: - Version selection, notes autosave, re-transcribe

public extension MeetingDetailViewModel {
    /// Selects and loads a specific transcript version.
    func selectVersion(_ versionID: UUID) async {
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

    /// Updates notes and debounces autosave to the store.
    ///
    /// Uses `[weak self]` for the short debounce window. If the VM
    /// deallocs mid-debounce, `flushNotes()` (called in `onDisappear`)
    /// is the guarantee that pending edits are persisted before teardown.
    func updateNotes(_ text: String) {
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

    /// Flushes any pending notes and title changes immediately and stops
    /// playback. Called on navigation away (onDisappear) to prevent
    /// leaked timers and lost edits.
    func flushNotes() async {
        notesAutosaveTask?.cancel()
        notesAutosaveTask = nil
        stopPlayback()
        await saveNotes()
        await saveTitle()
    }

    /// Dismisses the re-transcribe prompt and triggers re-transcription.
    func reTranscribeAfterCorrection() async {
        showReTranscribeAfterCorrection = false
        await reTranscribe()
    }
}

// MARK: - Transcript display helpers

public extension MeetingDetailViewModel {
    /// Whether the meeting has ever been transcribed (has at least one
    /// transcript version), even if the transcript is empty.
    var hasBeenTranscribed: Bool {
        !versions.isEmpty
    }

    /// Non-mutating check: true when the displayed transcript has segments.
    /// Safe to call during SwiftUI `body` evaluation (no state mutation).
    var hasDisplayableTranscript: Bool {
        guard let transcript = displayedTranscript,
              !transcript.segments.isEmpty
        else { return false }
        return true
    }
}

// MARK: - Deep-link jump

public extension MeetingDetailViewModel {
    /// Token that changes whenever `core.pendingTranscriptJump` changes.
    /// The view observes this via `.onChange` to trigger
    /// `applyPendingJumpIfNeeded`.
    var pendingJumpToken: TranscriptJump? {
        core.pendingTranscriptJump
    }

    /// Checks for a pending transcript jump targeting this meeting.
    /// If found, switches to the Transcript tab, seeks to the requested
    /// time (clamped to duration), and consumes the jump. If audio
    /// is not yet loaded, stores the seek as `pendingSeek` to be
    /// applied when `loadAudioPlayer()` completes.
    func applyPendingJumpIfNeeded() async {
        guard let jump = core.pendingTranscriptJump,
              jump.meetingID == meetingID
        else { return }

        selectedTab = .transcript
        pendingSeek = jump.time
        applySeekIfReady()
        core.consumeTranscriptJump()
    }

    /// Applies `pendingSeek` if the audio player is loaded and has a
    /// known duration. Clamps the seek time to `[0, duration]`.
    internal func applySeekIfReady() {
        guard let seekTime = pendingSeek else { return }
        guard audioPlayer != nil, playbackDuration > 0 else {
            // Audio not loaded yet; pendingSeek will be applied
            // after loadAudioPlayer() completes.
            return
        }
        let clamped = min(max(0, seekTime), playbackDuration)
        seekAndPlay(to: clamped)
        pendingSeek = nil
    }
}

// MARK: - Calendar card mapping

public extension MeetingDetailViewModel {
    /// Whether audio files are present on disk for this meeting.
    var hasAudioFiles: Bool {
        isAudioAvailable
    }

    /// Builds `CalendarCardData` from the loaded calendar context, or nil
    /// if no event is linked. Pure mapping; the helpers are testable.
    var calendarCard: CalendarCardData? {
        guard let ctx = calendarContext else { return nil }

        // Deduplicate: organizer first, then attendees not already included.
        var seenIDs: Set<UUID> = []
        var people: [AvatarPerson] = []
        if let org = ctx.organizer {
            seenIDs.insert(org.id)
            people.append(AvatarPerson(displayName: org.name, email: org.email))
        }
        for att in ctx.attendees where seenIDs.insert(att.id).inserted {
            people.append(AvatarPerson(displayName: att.name, email: att.email))
        }
        let total = people.count

        return CalendarCardData(
            attendees: people,
            attendeeTotal: total,
            summary: Self.attendeeSummary(
                organizer: ctx.organizer, attendees: ctx.attendees
            ),
            whenText: TimeFormatting.whenText(start: ctx.startDate, end: ctx.endDate),
            platform: ctx.conferencePlatform,
            conferenceURL: ctx.conferenceURL,
            location: ctx.location,
            eventNotes: ctx.eventNotes,
            invitedText: Self.invitedText(
                organizer: ctx.organizer, attendees: ctx.attendees
            )
        )
    }
}

// MARK: - Transcription & association actions

public extension MeetingDetailViewModel {
    /// Triggers a re-transcription of the meeting.
    func reTranscribe() async {
        await core.transcription.reTranscribe(meetingID: meetingID)
        await load()
    }

    /// Retries a failed transcription.
    func retry() async {
        await core.transcription.transcribe(meetingID: meetingID)
        await load()
    }

    /// Corrects the association to a new event (or removes it if nil).
    func correctAssociation(eventKey: String?) async {
        await core.correctAssociation(
            meetingID: meetingID, eventKey: eventKey
        )
        await load()
        await core.reloadSummaries()
        showEventPicker = false
        // TODO(re-transcribe-prompt): restore setting
        // showReTranscribeAfterCorrection = true when vocab support
        // (Phase 9) lands. Suppressed because re-transcription without
        // vocabulary changes has no user-visible benefit.
    }

    /// Removes the calendar association.
    func removeAssociation() async {
        await correctAssociation(eventKey: nil)
        showReTranscribeAfterCorrection = false
    }

    /// Dismisses the re-transcribe prompt.
    func dismissReTranscribePrompt() {
        showReTranscribeAfterCorrection = false
    }
}

// MARK: - Calendar deep link, nearby events, title save

public extension MeetingDetailViewModel {
    /// Opens the event picker and fetches events near the meeting's
    /// recording time so past events are available for association.
    func presentAssociationCorrection() async {
        showEventPicker = true
        await loadNearbyEvents()
    }

    /// Fetches calendar events near the meeting's recording time
    /// (startDate or createdAt). Called when the picker opens.
    func loadNearbyEvents() async {
        guard let referenceDate = detail?.date else { return }
        isLoadingNearbyEvents = true
        nearbyEvents = await core.eventsNear(referenceDate)
        isLoadingNearbyEvents = false
    }

    /// Opens the associated calendar event in Calendar.app via the
    /// shared `CalendarDeepLink` helper.
    func openInCalendar() {
        if let url = CalendarDeepLink.calendarAppURL(
            eventIdentifier: calendarContext?.eventIdentifier,
            startDate: calendarContext?.startDate
        ) {
            urlOpener(url)
        }
    }

    /// Reveals the meeting's audio files in Finder. No-op if no files exist.
    func revealInFinder() {
        guard isAudioAvailable else { return }
        Task {
            do {
                let refs = try await core.store.audioFileRefs(
                    meetingID: meetingID
                )
                let urls = [refs.mic, refs.system].compactMap(\.self)
                guard !urls.isEmpty else { return }
                NSWorkspace.shared.activateFileViewerSelecting(urls)
            } catch {
                // Non-fatal; Finder reveal is best-effort.
            }
        }
    }

    /// Saves the current `editableTitle` to the store. Called on submit
    /// (Enter key) and on blur (focus loss) to prevent losing edits.
    ///
    /// **Guard:** only persists (and flags `editedTitle`) when the trimmed
    /// title differs from the currently-stored title. Without this guard,
    /// `flushNotes()` (called unconditionally on every `onDisappear`) and
    /// `.onSubmit` would set `editedTitle = true` on every viewed meeting,
    /// permanently blocking `applyEventTitle` from updating the title when
    /// the user links or re-links a calendar event.
    func saveTitle() async {
        let trimmed = editableTitle
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            // Revert to the stored title if the user blanked it out
            editableTitle = detail?.title ?? ""
            return
        }

        // Skip the write if the title hasn't actually changed --
        // avoids spuriously setting editedTitle on every navigation.
        guard trimmed != detail?.title else { return }

        editableTitle = trimmed
        do {
            try await core.store.setTitle(trimmed, for: meetingID)
            // Refresh the detail snapshot so `title` stays consistent
            detail = try await core.store.meetingDetail(id: meetingID)
            await core.reloadSummaries()
        } catch {
            // Non-fatal; title will be retried on next edit.
        }
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

            guard refs.present else {
                audioPlayer = nil
                syncPlaybackState()
                return
            }

            // Collect whichever audio files exist (mic, system, or both).
            var urls: [URL] = []
            if let mic = refs.mic { urls.append(mic) }
            if let sys = refs.system { urls.append(sys) }

            guard !urls.isEmpty else {
                audioPlayer = nil
                syncPlaybackState()
                return
            }

            let player = makePlayer()
            try player.load(urls: urls)
            audioPlayer = player
            syncPlaybackState()

            // Apply any pending deep-link seek that arrived before
            // the audio player was loaded.
            applySeekIfReady()
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

// MARK: - Calendar card helpers

extension MeetingDetailViewModel {
    /// Builds a summary like "Steve (organizer) \u{00B7} Alex \u{00B7} Jay \u{00B7} +2".
    ///
    /// - Cap visible names at 5; overflow shown as "+N".
    /// - Returns nil when both organizer and attendees are empty.
    static func invitedText(
        organizer: PersonData?, attendees: [PersonData]
    ) -> String? {
        var parts: [String] = []

        if let org = organizer {
            parts.append("\(org.name) (organizer)")
        }

        // Dedup attendees against organizer
        let organizerID = organizer?.id
        let filteredAttendees = attendees.filter { $0.id != organizerID }

        let maxVisible = 5
        let remaining = max(0, parts.count + filteredAttendees.count - maxVisible)
        let attendeesToShow = filteredAttendees.prefix(maxVisible - parts.count)

        parts.append(contentsOf: attendeesToShow.map(\.name))

        if remaining > 0 {
            parts.append("+\(remaining)")
        }

        guard !parts.isEmpty else { return nil }
        return parts.joined(separator: " \u{00B7} ")
    }

    /// Builds the attendee summary `AttributedString` for Row A of the card.
    ///
    /// Organizer name is medium weight / `.ink`; remaining names are
    /// `.inkSecondary`.
    static func attendeeSummary(
        organizer: PersonData?, attendees: [PersonData]
    ) -> AttributedString {
        var result = AttributedString()

        if let org = organizer {
            var orgStr = AttributedString(org.name)
            orgStr.font = .system(size: 13, weight: .medium)
            orgStr.foregroundColor = .ink
            result.append(orgStr)

            let organizerID = org.id
            let others = attendees.filter { $0.id != organizerID }
            if !others.isEmpty {
                let otherNames = others.prefix(2).map(\.name)
                let remaining = others.count - otherNames.count
                let suffix = if remaining > 0 {
                    ", " + otherNames.joined(separator: ", ")
                        + " and \(remaining) other\(remaining == 1 ? "" : "s")"
                } else {
                    ", " + otherNames.joined(separator: ", ")
                }
                var suffixStr = AttributedString(suffix)
                suffixStr.font = .system(size: 13)
                suffixStr.foregroundColor = .inkSecondary
                result.append(suffixStr)
            }
        } else if !attendees.isEmpty {
            let names = attendees.prefix(3).map(\.name)
            let remaining = attendees.count - names.count
            var text = names.joined(separator: ", ")
            if remaining > 0 {
                text += " and \(remaining) other\(remaining == 1 ? "" : "s")"
            }
            var str = AttributedString(text)
            str.font = .system(size: 13)
            str.foregroundColor = .inkSecondary
            result.append(str)
        }

        return result
    }
}

// MARK: - Delete meeting

public extension MeetingDetailViewModel {
    /// Presents the delete confirmation dialog.
    func requestDelete() {
        showDeleteConfirmation = true
    }

    /// Confirms deletion: stops playback, deletes files + DB row, navigates away.
    func confirmDelete() async {
        isDeleting = true
        stopPlayback()
        notesAutosaveTask?.cancel()
        notesAutosaveTask = nil
        await core.deleteMeeting(meetingID: meetingID)
        isDeleting = false
    }
}
