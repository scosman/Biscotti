import AppCore
import DataStore
import Foundation
import TranscriptionService

/// The three display states of the Meeting Detail screen.
public enum MeetingDetailState: Sendable, Equatable {
    /// Model download or transcription is in progress.
    case processing(message: String)

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
@MainActor @Observable
public final class MeetingDetailViewModel {
    private let core: AppCore
    private let meetingID: UUID

    /// The meeting detail data loaded from the store.
    public private(set) var detail: MeetingDetailData?

    /// The loading flag for the initial data fetch.
    public private(set) var isLoading: Bool = true

    public init(core: AppCore, meetingID: UUID) {
        self.core = core
        self.meetingID = meetingID
    }

    // MARK: - Derived state

    /// The current display state, combining the transcription job status
    /// and the persisted meeting detail.
    public var displayState: MeetingDetailState {
        let jobStatus = core.transcription.jobs[meetingID]

        switch jobStatus {
        case let .downloadingModel(message):
            return .processing(message: message)

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
            // No transcript yet and no active job -- show the detail as-is
            // (e.g. a meeting that was recorded but never transcribed).
            if let detail {
                return .transcript(detail)
            }
            // Load completed but no detail found (meeting deleted or not found).
            return .failed(message: "Meeting not found.", retriable: false)
        }
    }

    /// Whether the Re-transcribe action should be enabled.
    /// Available when the meeting has audio and no job is actively running.
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

    // MARK: - Actions

    /// Loads the meeting detail from the store.
    public func load() async {
        isLoading = true
        do {
            detail = try await core.store.meetingDetail(id: meetingID)
        } catch {
            detail = nil
        }
        isLoading = false
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
