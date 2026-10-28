import Foundation
import LiveTranscriptionService
import LiveTranscriptModel

/// Where the Transcript tab reads a meeting's live draft.
///
/// `MeetingDetailViewModel` reads `core.liveTranscription` unless a test
/// passes another source. The live service's drafts are observable, so the
/// view updates when a draft changes. Whether the final pass waits for a
/// recording to stop comes from `TranscriptionService.jobs`
/// (`.queued(.waitingForRecording)`).
public struct LiveDraftSource: Sendable {
    public var draft: @MainActor @Sendable (UUID) -> LiveTranscriptSnapshot?

    public init(draft: @escaping @MainActor @Sendable (UUID) -> LiveTranscriptSnapshot?) {
        self.draft = draft
    }

    /// No live transcription: no drafts.
    public static var none: LiveDraftSource {
        LiveDraftSource(draft: { _ in nil })
    }
}

public extension LiveDraftSource {
    /// The drafts of the app's live transcription service.
    @MainActor
    static func live(_ service: LiveTranscriptionService) -> LiveDraftSource {
        LiveDraftSource(draft: { [weak service] in service?.draft(for: $0) })
    }
}
