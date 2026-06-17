import AppCore
import AppKit
import Calendar
import DataStore
import DesignSystem
import Foundation
import Permissions
import Recording

// MARK: - Left chip state

/// The display state for the Left/Over time chip.
public enum LeftChip: Equatable, Sendable {
    /// No scheduled end -- only show Elapsed.
    case none
    /// More than 5 minutes remaining.
    case normal(String)
    /// 5 minutes or less remaining (amber warning).
    case warning(String)
    /// Past the scheduled end -- overtime count-up.
    case overtime(String)
}

/// View model for the active-recording screen.
///
/// Projects `AppCore.recording.state` into display-ready values,
/// loads the meeting detail for title/submeta/chips, proxies notes
/// to `RecordingController`, and forwards stop actions to `AppCore`.
@MainActor @Observable
public final class RecordingViewModel {
    private let core: AppCore

    /// Injectable URL opener (default NSWorkspace; tests inject a spy).
    private let urlOpener: (URL) -> Void

    /// The meeting detail loaded from the store.
    public private(set) var detail: MeetingDetailData?

    /// The user-editable title, two-way bound to `EditableMeetingTitle`.
    public var editableTitle: String = ""

    /// The title as last loaded from the store. Used to detect whether
    /// the user has made a local edit that should not be clobbered by
    /// a background reload (e.g. when the calendar association arrives
    /// after the initial load).
    private var lastLoadedTitle: String = ""

    /// Monotonic version token from `AppCore` that increments on every
    /// `reloadSummaries()` call. The view observes this via `.onChange`
    /// to trigger `reloadDetail()` after any summaries refresh (e.g.
    /// calendar association, stop, title change). More robust than
    /// watching `summaries.count` which misses same-count mutations.
    public var summariesVersion: Int {
        core.summariesVersion
    }

    public init(
        core: AppCore,
        urlOpener: @escaping (URL) -> Void = { url in
            NSWorkspace.shared.open(url)
        }
    ) {
        self.core = core
        self.urlOpener = urlOpener
    }

    // MARK: - Projected state

    /// Whether a recording is in progress.
    public var isRecording: Bool {
        core.recording.state.isRecording
    }

    /// The meeting ID of the current recording, or nil.
    public var meetingID: UUID? {
        core.recording.state.meetingID
    }

    /// The formatted elapsed time (e.g. "02:14").
    public var elapsedText: String {
        Self.formatElapsed(core.recording.state.elapsed)
    }

    /// Whether the system-audio denial banner should be shown.
    public var showSystemAudioWarning: Bool {
        core.recording.systemAudioWarning
    }

    /// The URL to open System Settings for system audio fix.
    public var systemAudioSettingsURL: URL {
        core.permissions.settingsURL(for: .systemAudio)
    }

    // MARK: - Meeting detail load

    /// Loads the meeting detail from the store. Called via `.task(id:)`
    /// on initial appearance. Always sets `editableTitle` because this
    /// is the first load for a new meeting ID.
    public func load() async {
        guard let meetingID else {
            detail = nil
            return
        }
        do {
            detail = try await core.store.meetingDetail(id: meetingID)
            if let loaded = detail {
                editableTitle = loaded.title
                lastLoadedTitle = loaded.title
            }
        } catch {
            detail = nil
        }
    }

    /// Reloads the meeting detail from the store in response to an
    /// external change (e.g. calendar association set the event title).
    ///
    /// Unlike `load()`, this only updates `editableTitle` when the user
    /// has NOT made a local edit -- i.e. `editableTitle` still matches
    /// `lastLoadedTitle`. This prevents clobbering an in-progress edit
    /// while still picking up the event title that the association path
    /// wrote to the store after the initial load.
    public func reloadDetail() async {
        guard let meetingID else { return }
        do {
            detail = try await core.store.meetingDetail(id: meetingID)
            if let loaded = detail {
                let userHasEdited = editableTitle != lastLoadedTitle
                if !userHasEdited {
                    editableTitle = loaded.title
                    lastLoadedTitle = loaded.title
                }
            }
        } catch {
            // Non-fatal: keep current detail on reload failure.
        }
    }

    // MARK: - Title

    /// Saves the editable title to the store, mirroring
    /// `MeetingDetailViewModel.saveTitle()`.
    public func saveTitle() async {
        guard let meetingID else { return }
        let trimmed = editableTitle
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            editableTitle = detail?.title ?? ""
            lastLoadedTitle = editableTitle
            return
        }
        guard trimmed != detail?.title else { return }
        editableTitle = trimmed
        do {
            try await core.store.setTitle(trimmed, for: meetingID)
            detail = try await core.store.meetingDetail(id: meetingID)
            lastLoadedTitle = trimmed
            await core.reloadSummaries()
        } catch {
            // Non-fatal
        }
    }

    // MARK: - Submeta

    /// Whether the meeting has a linked calendar event.
    public var hasEvent: Bool {
        detail?.calendar != nil
    }

    /// The event time range text, e.g. "10:00 - 10:30 AM".
    public var scheduleText: String? {
        guard let cal = detail?.calendar,
              let start = cal.startDate
        else { return nil }
        return Self.buildScheduleText(start: start, end: cal.endDate)
    }

    /// The conference platform name (e.g. "Google Meet"), if known.
    public var platformText: String? {
        guard let platform = detail?.calendar?.conferencePlatform,
              !platform.isEmpty
        else { return nil }
        return platform
    }

    /// Opens the linked event in Calendar.app.
    public func openInCalendar() {
        guard let cal = detail?.calendar else { return }
        if let url = CalendarDeepLink.calendarAppURL(
            eventIdentifier: cal.eventIdentifier,
            startDate: cal.startDate
        ) {
            urlOpener(url)
        }
    }

    /// The "Started {clock}" text for ad-hoc recordings.
    public var startedClockText: String? {
        guard let date = detail?.date else { return nil }
        return Self.buildStartedClockText(date: date)
    }

    // MARK: - Time chips

    /// The wall-clock time when the recording started, if any.
    ///
    /// Used by `TimelineView` to compute elapsed time from a shared `now`,
    /// so ELAPSED and LEFT/OVER chips are perfectly synchronised.
    public var recordingStartDate: Date? {
        core.recording.state.startDate
    }

    /// The scheduled end date from the linked event, if any.
    public var scheduledEnd: Date? {
        detail?.calendar?.endDate
    }

    /// Computes the elapsed time string from `startDate` and `now`.
    ///
    /// Named `computeElapsed` (not `elapsedText`) to avoid collision
    /// with the instance property `elapsedText` which reads the engine's
    /// async elapsed pump (used by menu bar / app shell). This static
    /// function is used by the recording pane's `TimelineView` where
    /// both chips must derive from the same `now`.
    ///
    /// Pure function, unit-tested.
    public static func computeElapsed(
        startDate: Date?, now: Date
    ) -> String {
        guard let start = startDate else { return "00:00" }
        let interval = max(0, now.timeIntervalSince(start))
        return formatElapsed(interval)
    }

    /// Computes the Left chip state from a scheduled end and current time.
    /// Pure function, unit-tested.
    public static func leftChip(
        scheduledEnd: Date?, now: Date
    ) -> LeftChip {
        guard let end = scheduledEnd else { return .none }
        let remaining = end.timeIntervalSince(now)
        if remaining <= 0 {
            let overtime = -remaining
            return .overtime("+" + formatChipTime(overtime))
        }
        let label = formatChipTime(remaining)
        if remaining <= 300 {
            return .warning(label)
        }
        return .normal(label)
    }

    // MARK: - Notes proxy

    /// In-memory notes, newest-first for display.
    public var notes: [MeetingNote] {
        core.recording.notes.reversed()
    }

    /// Adds a note with the current elapsed timestamp.
    public func addNote(_ text: String) {
        core.recording.addNote(text: text)
    }

    /// Updates an existing note's text (timestamp preserved).
    public func updateNote(id: UUID, text: String) {
        core.recording.updateNote(id: id, text: text)
    }

    /// Removes a note by its stable ID.
    public func removeNote(id: UUID) {
        core.recording.removeNote(id: id)
    }

    // MARK: - Auto-stop

    /// The auto-stop countdown state, if active for THIS recording.
    /// Returns nil when there is no countdown or when the countdown
    /// belongs to a different meeting (defensive).
    public var autoStopCountdown: AutoStopState? {
        guard let state = core.autoStop,
              state.meetingID == core.recording.state.meetingID
        else { return nil }
        return state
    }

    /// Cancels the auto-stop countdown so recording continues.
    public func keepRecording() {
        core.keepRecording()
    }

    // MARK: - Actions

    /// Commits any pending composer text, then stops the recording.
    public func stop(pendingComposer: String = "") async {
        let trimmed = pendingComposer
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty {
            core.recording.addNote(text: trimmed)
        }
        await core.stopRecording()
    }

    // MARK: - Formatting

    /// Formats a time interval as "MM:SS" or "H:MM:SS" for large values.
    static func formatElapsed(_ elapsed: TimeInterval) -> String {
        let totalSeconds = Int(elapsed)
        let hours = totalSeconds / 3600
        let minutes = (totalSeconds % 3600) / 60
        let seconds = totalSeconds % 60

        if hours > 0 {
            return String(format: "%d:%02d:%02d", hours, minutes, seconds)
        }
        return String(format: "%02d:%02d", minutes, seconds)
    }

    /// Formats a time interval for chip display: "m:ss" or "h:mm:ss".
    static func formatChipTime(_ interval: TimeInterval) -> String {
        let total = max(0, Int(interval))
        let hours = total / 3600
        let minutes = (total % 3600) / 60
        let seconds = total % 60

        if hours > 0 {
            return String(format: "%d:%02d:%02d", hours, minutes, seconds)
        }
        return String(format: "%d:%02d", minutes, seconds)
    }

    /// Builds the schedule text for event submeta.
    static func buildScheduleText(start: Date, end: Date?) -> String {
        let timeFormatter = DateFormatter()
        timeFormatter.setLocalizedDateFormatFromTemplate("j:mm")
        let endTimeFormatter = DateFormatter()
        endTimeFormatter.setLocalizedDateFormatFromTemplate("j:mm a")

        let startStr = timeFormatter.string(from: start)
        guard let end else { return startStr }
        let endStr = endTimeFormatter.string(from: end)
        return "\(startStr) \u{2013} \(endStr)"
    }

    /// Builds the "Started {clock}" text for ad-hoc submeta.
    static func buildStartedClockText(date: Date) -> String {
        let formatter = DateFormatter()
        formatter.setLocalizedDateFormatFromTemplate("j:mm a")
        return "Started \(formatter.string(from: date))"
    }

    /// Formats a note timestamp as "m:ss" or "h:mm:ss".
    public static func formatNoteTimestamp(
        _ seconds: TimeInterval
    ) -> String {
        formatChipTime(seconds)
    }
}
