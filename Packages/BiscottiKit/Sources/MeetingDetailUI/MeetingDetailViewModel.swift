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
/// and the upcoming event picker.
@MainActor @Observable
public final class MeetingDetailViewModel {
    private let core: AppCore
    private let meetingID: UUID

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

    public init(core: AppCore, meetingID: UUID) {
        self.core = core
        self.meetingID = meetingID
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

    // MARK: - Actions

    /// Loads the meeting detail from the store.
    public func load() async {
        isLoading = true
        do {
            detail = try await core.store.meetingDetail(id: meetingID)
            calendarContext = detail?.calendar
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

    // MARK: - Formatting

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
