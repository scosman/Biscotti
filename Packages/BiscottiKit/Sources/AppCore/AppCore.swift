import DataStore
import Foundation
import Permissions
import Recording
import TranscriptionService

/// Thin MVP coordinator that wires Recording, TranscriptionService,
/// Permissions, and DataStore into a single observable surface for the UI.
///
/// The UI observes `route` and `summaries` to drive navigation and the
/// sidebar list. Heavy work is delegated to the injected services; this
/// class owns only the coordination logic (launch recovery, start/stop
/// sequencing, auto-transcribe on stop, routing).
@MainActor @Observable
public final class AppCore {
    // MARK: - Published state

    /// The current navigation destination.
    public private(set) var route: Route = .home

    /// The sidebar meeting list (newest first).
    public private(set) var summaries: [MeetingSummary] = []

    // MARK: - Child services (publicly readable for the UI layer)

    /// The persistent store.
    public let store: DataStore

    /// Mic + system-audio permission state.
    public let permissions: Permissions

    /// Recording lifecycle controller.
    public let recording: RecordingController

    /// Transcription orchestration.
    public let transcription: TranscriptionService

    // MARK: - Private

    /// Cap for the sidebar query so it stays fast. The full list / search /
    /// pagination is a later project (Project 7).
    private let summaryLimit: Int

    /// The fire-and-forget transcription task spawned by `stopRecording()`.
    /// Retained so tests can deterministically await completion instead of
    /// relying on fixed sleep durations.
    package var pendingTranscriptionTask: Task<Void, Never>?

    // MARK: - Init

    /// Creates an `AppCore` from pre-built services (used by tests and the
    /// `live` factory).
    ///
    /// - Parameters:
    ///   - store: The DataStore actor.
    ///   - permissions: The Permissions instance.
    ///   - recording: The RecordingController.
    ///   - transcription: The TranscriptionService.
    ///   - summaryLimit: Max meetings to load for the sidebar (default 50).
    public init(
        store: DataStore,
        permissions: Permissions,
        recording: RecordingController,
        transcription: TranscriptionService,
        summaryLimit: Int = 50
    ) {
        self.store = store
        self.permissions = permissions
        self.recording = recording
        self.transcription = transcription
        self.summaryLimit = summaryLimit
    }

    // MARK: - Lifecycle

    /// Called once at app launch. Recovers orphaned recordings from a
    /// previous crash, then loads the sidebar list.
    public func onLaunch() async {
        await recording.recoverOrphans()
        await reloadSummaries()
    }

    // MARK: - Recording coordination

    /// Starts a new recording session and routes to the recording screen.
    ///
    /// If the recording fails to start (permission denied, engine error),
    /// the route stays unchanged and `recording.lastError` surfaces the
    /// cause for the UI.
    public func startRecording() async {
        await recording.start()
        if recording.state.isRecording {
            route = .recording
        }
    }

    /// Stops the current recording, reloads the sidebar, routes to the
    /// meeting detail, and auto-enqueues transcription.
    ///
    /// Returns `nil` if there was no active recording.
    @discardableResult
    public func stopRecording() async -> UUID? {
        guard let meetingID = await recording.stop() else {
            return nil
        }

        await reloadSummaries()
        route = .meeting(meetingID)

        // Fire-and-forget transcription. The service manages its own
        // status observable (`jobs[meetingID]`) so the UI reacts without
        // blocking stop. The task is retained so tests can await it
        // deterministically via `awaitPendingTranscription()`.
        pendingTranscriptionTask = Task { @MainActor [transcription] in
            await transcription.transcribe(meetingID: meetingID)
        }

        return meetingID
    }

    // MARK: - Navigation

    /// Selects a meeting in the sidebar and routes to its detail.
    public func select(_ meetingID: UUID) {
        route = .meeting(meetingID)
    }

    /// Routes the detail pane to the recording screen.
    ///
    /// Used when the user taps the sidebar recording indicator to return
    /// to the recording view after navigating to a past meeting.
    public func navigateToRecording() {
        guard recording.state.isRecording else { return }
        route = .recording
    }

    // MARK: - Data refresh

    /// Reloads the sidebar summaries from the store.
    public func reloadSummaries() async {
        do {
            summaries = try await store.meetingSummaries(limit: summaryLimit)
        } catch {
            // Non-fatal: the UI shows a stale (or empty) list. A persistent
            // failure here would indicate a broken store, which will surface
            // through other paths (recording/transcription errors).
            summaries = []
        }
    }

    // MARK: - Test support

    /// Waits for any pending fire-and-forget transcription task spawned by
    /// `stopRecording()` to finish.
    ///
    /// Exposed at package visibility so tests can deterministically observe
    /// transcription completion instead of relying on fixed sleep durations.
    package func awaitPendingTranscription() async {
        await pendingTranscriptionTask?.value
        pendingTranscriptionTask = nil
    }
}
